using Gtk;
using Pango;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using WrapMode = Gtk.WrapMode;

namespace Shelly.Gtk.Windows.Dialog;

public static class PkgbuildPreview
{
    public static void ShowPackageBuildPreview(PackageBuildEventArgs e, IGenericQuestionService questionService)
    {
        var tcs = new TaskCompletionSource<bool>(); // Opcional: se quiser usar como Task<bool> no futuro

        var dialog = Window.New();
        
        dialog.SetTitle(e.Title);                      
        dialog.SetTransientFor(null);                  
        dialog.SetModal(true);                         
        dialog.SetDefaultSize(900, 650);               

        var outer = Box.New(Orientation.Vertical, 12);
        
        var headerBox = Box.New(Orientation.Horizontal, 0);
        headerBox.SetMarginTop(4);

        var closeButton = Button.New();
        closeButton.SetIconName("window-close-symbolic");
        closeButton.TooltipText = "Close Preview";
        
        closeButton.OnClicked += (_, _) =>
        {
            tcs.TrySetResult(false);
            dialog.Close();
        };

        var copyButton = Button.New();
        if (!string.IsNullOrEmpty(e.PkgBuild))
        {
            copyButton.SetIconName("edit-copy-symbolic"); 
            copyButton.TooltipText = "Copy PKGBUILD to clipboard";
            copyButton.OnClicked += (_, _) =>
            {
                var clipboard = copyButton.GetClipboard();
                clipboard.SetText(e.PkgBuild);
            };
        }

        var titleLabel = Label.New(e.Title);
        titleLabel.AddCssClass("title-4");
        titleLabel.SetHexpand(true);
        titleLabel.SetXalign(0.5f);
        titleLabel.SetMarginEnd(40);

        headerBox.Append(copyButton);
        headerBox.Append(titleLabel);
        headerBox.Append(closeButton);

        outer.Append(headerBox);

        var textView = TextView.New();
        if (!string.IsNullOrEmpty(e.PkgBuild))
        {
            textView.WrapMode = WrapMode.WordChar;
            textView.Editable = false;          
            textView.Monospace = true;        
            textView.CursorVisible = false;
            textView.LeftMargin = 12;
            textView.RightMargin = 12;
            textView.TopMargin = 12;
            textView.BottomMargin = 12;
            textView.GetBuffer().SetText(e.PkgBuild, -1);

            var scrolledWindow = ScrolledWindow.New();
            scrolledWindow.SetPolicy(PolicyType.Automatic, PolicyType.Automatic);
            scrolledWindow.SetVexpand(true);
            scrolledWindow.SetHexpand(true);
            scrolledWindow.AddCssClass("view"); 
            scrolledWindow.SetChild(textView);

            outer.Append(scrolledWindow);
        }
        
        foreach (var (name, content) in e.SourceFiles)
        {
            if (string.IsNullOrEmpty(content)) continue;

            var sourceLabel = Label.New(name);
            sourceLabel.AddCssClass("heading");
            sourceLabel.SetXalign(0);
            sourceLabel.SetMarginStart(12);
            outer.Append(sourceLabel);

            var sourceView = TextView.New();
            sourceView.SetWrapMode(WrapMode.WordChar);
            sourceView.Editable = false;
            sourceView.Monospace = true;
            sourceView.CursorVisible = false;
            sourceView.LeftMargin = 12;
            sourceView.RightMargin = 12;
            sourceView.TopMargin = 12;
            sourceView.BottomMargin = 12;
            sourceView.GetBuffer().SetText(content, -1);

            var sourceScroll = ScrolledWindow.New();
            sourceScroll.SetPolicy(PolicyType.Automatic, PolicyType.Automatic);
            sourceScroll.SetVexpand(true);
            sourceScroll.SetHexpand(true);
            sourceScroll.AddCssClass("view");
            sourceScroll.SetChild(sourceView);
            outer.Append(sourceScroll);
        }

        dialog.SetChild(outer);

        dialog.OnCloseRequest += (_, _) =>
        {
            tcs.TrySetResult(false);
            return false;
        };

        dialog.Present();

        closeButton.GrabFocus();
    }
}
