namespace PackageManager.Alpm.Questions;

public record ProviderOption(string Name, bool selected, bool isInstalled, string? Description);