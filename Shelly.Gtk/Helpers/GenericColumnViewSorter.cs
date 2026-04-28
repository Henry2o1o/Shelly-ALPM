using Gtk;
using Gio;
using Shelly.Gtk.UiModels.PackageManagerObjects.GObjects;

namespace Shelly.Gtk.Helpers;

public static class GenericColumnViewSorter
{
    public static void SortColumnByName(
        SortType order,
        Gio.ListStore listStore)
    {
        var items = new List<MetaPackageGObject>();

        for (uint i = 0; i < listStore.GetNItems(); i++)
        {
            if (listStore.GetObject(i) is MetaPackageGObject item)
                items.Add(item);
        }

        items.Sort((a, b) =>
        {
            return order switch
            {
                SortType.Ascending =>
                    string.Compare(
                        a.Package?.Name,
                        b.Package?.Name,
                        StringComparison.OrdinalIgnoreCase),

                SortType.Descending =>
                    string.Compare(
                        b.Package?.Name,
                        a.Package?.Name,
                        StringComparison.OrdinalIgnoreCase),

                _ => 0
            };
        });
        
        var objects = new GObject.Object[items.Count];

        for (int i = 0; i < items.Count; i++)
            objects[i] = items[i];
        
        listStore.Splice(
            0,
            listStore.GetNItems(),
            objects,
            (uint)items.Count
        );    
        
    }
}    
