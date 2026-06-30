namespace PackageManager.Tests.AlpmReferenceTests;

public class LibraryInitializationTests
{
    [Test]
    public void InitializeReturnsNonNullHandle()
    {
        var handle = Alpm.Reference.AlpmReference.Initialize("/","/var/lib/pacman",out var error);
        Assert.That(handle, Is.Not.EqualTo(IntPtr.Zero));
        var result = Alpm.Reference.AlpmReference.Release(handle);
        
    }
}