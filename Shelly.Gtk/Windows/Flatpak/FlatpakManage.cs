using Gtk;
using Shelly.Gtk.Enums;
using Shelly.Gtk.Helpers;
using Shelly.GTK.Resources;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects;
using Shelly.Gtk.Windows.Dialog;
using Shelly.Utilities;

// ReSharper disable CollectionNeverQueried.Local

namespace Shelly.Gtk.Windows.Flatpak;

public class FlatpakManage(
    IUnprivilegedOperationService unprivilegedOperationService,
    ILockoutService lockoutService,
    IGenericQuestionService genericQuestionService,
    IDirtyService dirtyService) : IShellyWindow, IReloadable
{
    private DirtySubscription? _sub;
    public string[] ListensTo => [DirtyScopes.FlatpakInstalled];
    private ListView? _listView;
    private readonly CancellationTokenSource _cts = new();
    private Gio.ListStore? _listStore;
    private SingleSelection? _selectionModel;
    private List<FlatpakPackageDto> _allPackages = [];
    private string _searchText = string.Empty;
    private SignalListItemFactory? _factory;
    private readonly List<StringObject> _stringObjectRefs = [];
    private CheckButton _showRuntimesCheck = null!;

    public Widget CreateWindow()
    {
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/Flatpak/FlatpakRemoveWindow.ui"), -1);
        var box = (Box)builder.GetObject("FlatpakRemoveWindow")!;

        _listView = (ListView)builder.GetObject("installed_flatpaks")!;
        var removeButton = (Button)builder.GetObject("remove_button")!;

        var flatpakRepairButton = (Button)builder.GetObject("flatpak_repair_button")!;
        _listStore = Gio.ListStore.New(StringObject.GetGType());
        _selectionModel = SingleSelection.New(_listStore);
        _listView.SetModel(_selectionModel);

        _factory = SignalListItemFactory.New();
        _factory.OnSetup += OnSetup;
        _factory.OnBind += OnBind;
        _listView.SetFactory(_factory);

        _listView.OnRealize += (_, _) => { _ = LoadDataAsync(_cts.Token); };
        removeButton.OnClicked += (_, _) => { _ = RemoveSelectedAsync(); };
        flatpakRepairButton.OnClicked += (_, _) => { _ = FlatpakRepairAsync(); };

        _showRuntimesCheck = (CheckButton)builder.GetObject("runtime_check")!;
        _showRuntimesCheck.Active = false;

        _showRuntimesCheck.OnToggled += (_, _) => { Reload(); };

        _sub = DirtySubscription.Attach(dirtyService, this);
        return box;
    }


    public void Reload() => _ = LoadDataAsync(_cts.Token);

    private static void OnSetup(SignalListItemFactory sender, SignalListItemFactory.SetupSignalArgs args)
    {
        var listItem = (ListItem)args.Object;
        
        var contentGrid = Grid.New();
        contentGrid.MarginStart = 12;
        contentGrid.MarginEnd = 12;
        contentGrid.MarginTop = 6;
        contentGrid.MarginBottom = 6;
        contentGrid.ColumnSpacing = 12;
        contentGrid.RowSpacing = 2;
        contentGrid.Hexpand = true;
        contentGrid.Valign = Align.Center;

        var icon = Image.New();
        icon.PixelSize = 48;
        icon.Valign = Align.Center;
        contentGrid.Attach(icon, 0, 0, 1, 2);

        var nameLabel = Label.New(string.Empty);
        nameLabel.Halign = Align.Start;
        contentGrid.Attach(nameLabel, 1, 0, 1, 1);

        var idLabel = Label.New(string.Empty);
        idLabel.Halign = Align.Start;
        idLabel.AddCssClass("dim-label");
        contentGrid.Attach(idLabel, 1, 1, 1, 1);

        var versionLabel = Label.New(string.Empty);
        versionLabel.Halign = Align.End;
        versionLabel.Hexpand = true;
        contentGrid.Attach(versionLabel, 2, 0, 1, 2);

        listItem.SetChild(contentGrid);
    }

    private void OnBind(SignalListItemFactory sender, SignalListItemFactory.BindSignalArgs args)
    {
        var listItem = (ListItem)args.Object;
        if (listItem.GetItem() is not StringObject stringObj) return;
        if (listItem.GetChild() is not Grid contentGrid) return;

        var packageId = stringObj.GetString();
        var package = _allPackages.FirstOrDefault(p => p.Id == packageId);
        if (package == null) return;

        var icon = (Image)contentGrid.GetChildAt(0, 0)!;
        var nameLabel = (Label)contentGrid.GetChildAt(1, 0)!;
        var idLabel = (Label)contentGrid.GetChildAt(1, 1)!;
        var versionLabel = (Label)contentGrid.GetChildAt(2, 0)!;

        string path;
        if (package.InstallLevel == InstallLevel.User)
        {
            path =
                Path.Combine(XdgPaths.DataHome(), "/flatpak/appstream", package.Remote,
                    "x86_64/active/icons/64x64", $"{package.Id}.png");
        }
        else
        {
            path =
                $"/var/lib/flatpak/appstream/{package.Remote}/x86_64/active/icons/64x64/{package.Id}.png";
        }

        if (File.Exists(path))
            icon.SetFromFile(path);
        else
            icon.SetFromIconName("application-x-executable");

        nameLabel.SetText(package.Name);
        idLabel.SetText(SizeHelpers.FormatSize(package.InstalledSize));
        versionLabel.SetText(package.Version);
    }

    private async Task FlatpakRepairAsync()
    {
        try
        {
            lockoutService.Show(Translations.T("Repaired Flatpak installation"));
            var exec = await unprivilegedOperationService.FlatpakRepair();
        }
        catch (OperationCanceledException)
        {
            genericQuestionService.RaiseToastMessage(new ToastMessageEventArgs(
                Translations.T($"Failed to repair Flatpak installation")));
        }
        finally
        {
            lockoutService.Hide();
        }
    }


    private async Task LoadDataAsync(CancellationToken ct = default)
    {
        try
        {
            var packages = await unprivilegedOperationService.ListFlatpakPackages();
            _allPackages = !_showRuntimesCheck.Active ? packages.Where(p => p.Kind == 0).ToList() : packages;

            ct.ThrowIfCancellationRequested();

            GLib.Functions.IdleAdd(0, () =>
            {
                ApplyFilter();
                return false;
            });
        }
        catch (Exception e)
        {
            Console.WriteLine($"Failed to load installed packages: {e.Message}");
        }
    }

    public void SetSearch(string text)
    {
        _searchText = text;
        ApplyFilter();
    }

    private void ApplyFilter()
    {
        if (_listStore == null) return;

        var filtered = string.IsNullOrWhiteSpace(_searchText)
            ? _allPackages
            : _allPackages.Where(p =>
                p.Name.Contains(_searchText, StringComparison.OrdinalIgnoreCase) ||
                p.Id.Contains(_searchText, StringComparison.OrdinalIgnoreCase));

        _listStore.RemoveAll();
        _stringObjectRefs.Clear();

        foreach (var package in filtered)
        {
            var strObj = StringObject.New(package.Id);
            _stringObjectRefs.Add(strObj);
            _listStore.Append(strObj);
        }
    }

    private async Task RemoveSelectedAsync()
    {
        var selectedItem = _selectionModel?.GetSelectedItem();
        if (selectedItem is not StringObject stringObj) return;

        var packageId = stringObj.GetString();
        bool removeConfig;

        var args = RemoveConfigDialogue.BuildRemoveDialog();

        genericQuestionService.RaiseDialog(args);

        var message = await args.ResponseTask;

        switch (message)
        {
            case ConfigRemoveEnum.Cancel:
                return;
            case ConfigRemoveEnum.KeepConfig:
                removeConfig = false;
                break;
            case ConfigRemoveEnum.RemoveConfig:
                removeConfig = true;
                break;
            default:
                throw new ArgumentOutOfRangeException();
        }

        try
        {
            lockoutService.Show(Translations.T("Removing {0}...", packageId));
            var result = await unprivilegedOperationService.RemoveFlatpakPackage(packageId, removeConfig);

            if (!result.Success)
            {
                Console.WriteLine(Translations.T("Failed to remove package {0}: {1}", packageId, result.Error));
            }
            else
            {
                await LoadDataAsync();
            }
        }
        finally
        {
            lockoutService.Hide();
            genericQuestionService.RaiseToastMessage(new ToastMessageEventArgs(
                Translations.T("Removed Package(s)")
            ));
        }
    }

    public void Dispose()
    {
        _sub?.Dispose();
        _cts.Cancel();
        _cts.Dispose();
        _listStore?.RemoveAll();
        _stringObjectRefs.Clear();
        _allPackages.Clear();
    }
}