namespace PackageManager.Alpm.Events.EventArgs;

public sealed record InformationalEventArgs(AlpmEventType EventType, string Message);