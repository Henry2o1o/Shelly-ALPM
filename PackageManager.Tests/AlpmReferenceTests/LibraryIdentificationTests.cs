namespace PackageManager.Tests.AlpmReferenceTests;

using PackageManager;

public class LibraryIdentificationTests
{
    [Test]
    public void SuccessfullyResolvesAlpmLibrary()
    {
        var isAvailable = NativeResolver.IsLibraryAvailable(Alpm.Reference.AlpmReference.LibName);
        Assert.That(isAvailable, Is.True);
    }
    
}