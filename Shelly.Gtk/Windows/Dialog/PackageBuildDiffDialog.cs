using Gtk;
using Pango;
using Shelly.Gtk.UiModels;
using static Shelly.GTK.Resources.Translations;
using WrapMode = Gtk.WrapMode;

namespace Shelly.Gtk.Windows.Dialog;

public static class PackageBuildDiffDialog
{
    public static void ShowPackageBuildDiffDialog(
        Overlay parentOverlay,
        PackageBuildDiffEventArgs e)
    {
        var baseFrame = Frame.New(null);
        baseFrame.SetHalign(Align.Center);
        baseFrame.SetValign(Align.Center);
        baseFrame.SetSizeRequest(1000, 700);
        baseFrame.SetMarginTop(20);
        baseFrame.SetMarginBottom(20);
        baseFrame.SetMarginStart(20);
        baseFrame.SetMarginEnd(20);
        baseFrame.AddCssClass("background");
        baseFrame.AddCssClass("dialog-overlay");
        baseFrame.SetOverflow(Overflow.Hidden);

        var rootBox = Box.New(Orientation.Vertical, 12);
        rootBox.SetMarginTop(12);
        rootBox.SetMarginBottom(12);
        rootBox.SetMarginStart(12);
        rootBox.SetMarginEnd(12);

        baseFrame.SetChild(rootBox);

        var titleLabel = Label.New($"PKGBUILD Diff - {e.PackageName}");
        titleLabel.AddCssClass("title-4");
        titleLabel.SetHalign(Align.Start);

        rootBox.Append(titleLabel);

        var descriptionLabel = Label.New(
            T("Review the PKGBUILD changes before continuing."));
        descriptionLabel.SetWrap(true);
        descriptionLabel.SetXalign(0);

        rootBox.Append(descriptionLabel);

        var diffBox = Box.New(Orientation.Horizontal, 12);
        diffBox.SetVexpand(true);
        diffBox.SetHexpand(true);

        diffBox.Append(CreatePkgbuildPanel(
            T("Previous PKGBUILD"),
            e.OldPkgbuild));

        diffBox.Append(CreatePkgbuildPanel(
            T("New PKGBUILD"),
            e.NewPkgbuild));

        rootBox.Append(diffBox);

        var buttonBox = Box.New(Orientation.Horizontal, 8);
        buttonBox.SetHalign(Align.End);

        var cancelButton = Button.NewWithLabel(T("Cancel"));
        var confirmButton = Button.NewWithLabel(T("Accept Changes"));

        confirmButton.AddCssClass("suggested-action");

        cancelButton.OnClicked += (_, _) =>
        {
            e.SetResponse(false);
            parentOverlay.RemoveOverlay(baseFrame);
        };

        confirmButton.OnClicked += (_, _) =>
        {
            e.SetResponse(true);
            parentOverlay.RemoveOverlay(baseFrame);
        };

        buttonBox.Append(cancelButton);
        buttonBox.Append(confirmButton);

        rootBox.Append(buttonBox);

        parentOverlay.AddOverlay(baseFrame);
    }

    private static Widget CreatePkgbuildPanel(
        string title,
        string content)
    {
        var panelBox = Box.New(Orientation.Vertical, 6);
        panelBox.SetHexpand(true);
        panelBox.SetVexpand(true);

        var titleLabel = Label.New(title);
        titleLabel.SetXalign(0);
        titleLabel.AddCssClass("heading");

        panelBox.Append(titleLabel);

        var buffer = TextBuffer.New(null);
        buffer.SetText(content, -1);

        var textView = TextView.NewWithBuffer(buffer);
        textView.SetEditable(false);
        textView.SetCursorVisible(false);
        textView.SetMonospace(true);
        textView.SetWrapMode(WrapMode.WordChar);
        textView.SetVexpand(true);
        textView.SetHexpand(true);

        var scroll = ScrolledWindow.New();
        scroll.SetPolicy(
            PolicyType.Automatic,
            PolicyType.Automatic);

        scroll.SetChild(textView);
        scroll.SetVexpand(true);
        scroll.SetHexpand(true);

        panelBox.Append(scroll);

        return panelBox;
    }
}