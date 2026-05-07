using System.Text.Json;
using System.Net.Http;
using Gtk;
using Shelly.Gtk.Enums;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services;
using Shelly.Gtk.Services.Icons;
using Shelly.Gtk.UiModels.PackageManagerObjects;
using Shelly.Gtk.UiModels.Recommend;
using Shelly.Gtk.UiModels.Recommend.GObjects;

namespace Shelly.Gtk.Windows;

public class Recommend(
    IPrivilegedOperationService privilegedOperationService,
    IUnprivilegedOperationService unprivilegedOperationService,
    IGenericQuestionService genericQuestionService,
    ILockoutService lockoutService,
    IDirtyService dirtyService,
    IIconResolverService iconResolverService) : IShellyWindow, IReloadable
{
    private static readonly HttpClient Client = new();
    private Box? _scrolledWindow;
    private readonly List<FlatRecommendModel> _packages = [];
    private readonly CancellationTokenSource _cts = new();

    public Widget CreateWindow()
    {
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/Recommend.ui"), -1);
        var box = (Box)builder.GetObject("ShellyRecommend")!;

        _scrolledWindow = (Box)builder.GetObject("recommend_scroll_window")!;
        _scrolledWindow.SetOrientation(Orientation.Vertical);
        _scrolledWindow.SetSpacing(10);

        _scrolledWindow.OnRealize += (_, _) => { _ = LoadDataAsync(_cts.Token); };

        return box;
    }

    private async Task LoadDataAsync(CancellationToken ct)
    {
        try
        {
            var alpmPackages = await privilegedOperationService.GetAvailablePackagesAsync();
            var installedPackages = await privilegedOperationService.GetInstalledPackagesAsync();

            var values = await Client.GetStringAsync("https://www.seafoam-labs.org/recommend.json", ct);

            var result = JsonSerializer.Deserialize(values, RecommendJsonContext.Default.ListRecommendModel) ?? [];
            _packages.Clear();
            foreach (var item in result)
            {
                if (!Enum.TryParse<RecommendCategory>(item.Name, out var category)) continue;
                foreach (var pkgName in item.Packages)
                {
                    _packages.Add(new FlatRecommendModel
                    {
                        Category = category,
                        Package = pkgName,
                        Description = alpmPackages.FirstOrDefault(x => x.Name == pkgName)?.Description ?? "",
                        IsInstalled = installedPackages.Any(x => x.Name == pkgName)
                    });
                }
            }

            await FlowChartBuilder();
        }
        catch (Exception e)
        {
            Console.WriteLine(e);
        }
    }

    private Task FlowChartBuilder()
    {
        try
        {
            foreach (var category in Enum.GetValues<RecommendCategory>())
            {
                var categoryPackages = _packages.Where(x => x.Category == category).ToList();
                if (categoryPackages.Count == 0) continue;

                var sectionBox = Box.New(Orientation.Vertical, 6);

                var label = Label.New(category.ToString());
                label.SetHalign(Align.Start);
                label.AddCssClass("title-4");

                var flox = FlowBox.New();
                flox.SetSelectionMode(SelectionMode.None);
                flox.SetColumnSpacing(12);
                flox.SetRowSpacing(12);
                flox.MinChildrenPerLine = 2;
                flox.MaxChildrenPerLine = 4;

                foreach (var item in categoryPackages)
                {
                    AddFlowBoxItem(flox, item);
                }

                sectionBox.Append(label);
                sectionBox.Append(flox);

                _scrolledWindow!.Append(sectionBox);
            }

            return Task.CompletedTask;
        }
        catch (Exception exception)
        {
            return Task.FromException(exception);
        }
    }

    private void AddFlowBoxItem(FlowBox flowBox, FlatRecommendModel item)
    {
        var contentBox = Box.New(Orientation.Horizontal, 12);
        contentBox.SetMarginTop(12);
        contentBox.SetMarginBottom(12);
        contentBox.SetMarginStart(12);
        contentBox.SetMarginEnd(12);
        contentBox.SetHexpand(true);

        var iconPath = iconResolverService.GetIconPath(item.Package);
        if (!string.IsNullOrEmpty(iconPath))
        {
            var image = Image.NewFromFile(iconPath);
            image.SetPixelSize(48);
            image.SetValign(Align.Center);
            contentBox.Append(image);
        }

        var textContainer = Box.New(Orientation.Vertical, 0);
        textContainer.SetValign(Align.Center);
        textContainer.SetHexpand(true);

        var titleContainer = Box.New(Orientation.Horizontal, 6);

        var titleLabel = Label.New(item.Package);
        titleLabel.SetHalign(Align.Start);
        titleLabel.AddCssClass("title-4");

        var installedCheck = Image.NewFromIconName("object-select-symbolic");
        installedCheck.SetVisible(item.IsInstalled);
        installedCheck.SetValign(Align.Center);

        titleContainer.Append(titleLabel);
        titleContainer.Append(installedCheck);

        var descLabel = Label.New(item.Description);
        descLabel.SetHalign(Align.Start);
        descLabel.AddCssClass("dim-label");
        descLabel.SetWrap(true);
        descLabel.SetWrapMode(Pango.WrapMode.WordChar);
        descLabel.SetEllipsize(Pango.EllipsizeMode.None);
        descLabel.MaxWidthChars = 25;

        textContainer.Append(titleContainer);
        textContainer.Append(descLabel);

        contentBox.Append(textContainer);

        var downloadButton = Button.NewFromIconName("folder-download-symbolic");
        downloadButton.AddCssClass("flat");
        downloadButton.SetValign(Align.Center);
        downloadButton.OnClicked += (_, _) =>
        {
            Console.WriteLine($"Download button clicked for package: {item.Package}");
        };

        contentBox.Append(downloadButton);

        var frame = Frame.New(null);
        frame.SetChild(contentBox);
        frame.WidthRequest = 300;
        frame.Hexpand = false;
        frame.Halign = Align.Fill;
        frame.AddCssClass("card");
        
        flowBox.Append(frame);
    }

    public string[] ListensTo { get; } = [];

    public void Reload()
    {
        // Never needs to reload logic here, since the data is static and the page handles the refreshing its state itself.
    }

    public void Dispose()
    {
        _packages.Clear();
        _cts.Dispose();
    }
}