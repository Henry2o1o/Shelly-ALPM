using System;


namespace Shelly.Utilities.Eventing;

public abstract record Event(EventSource Source, EventLevel Level, string Message, DateTimeOffset TimeStamp = default)
{
    public DateTimeOffset TimeStamp { get; init; } = TimeStamp == default ? DateTimeOffset.Now : TimeStamp;
}

// Records for alpm events
public sealed record CheckDependencyStartEvent() : Event(EventSource.Alpm, EventLevel.Information, $"Checking dependencies");

public sealed record CheckDependencyDoneEvent() : Event(EventSource.Alpm, EventLevel.Information, $"Dependencies check completed");

public sealed record FileConflictsStartEvent() : Event(EventSource.Alpm, EventLevel.Information, $"Checking for file conflicts");

public sealed record FileConflictsDoneEvent() : Event(EventSource.Alpm, EventLevel.Information, $"File conflict check completed");

public sealed record ResolveDependencyStartEvent() : Event(EventSource.Alpm, EventLevel.Information, $"Resolving dependencies");

public sealed record ResolveDependencyDoneEvent() : Event(EventSource.Alpm, EventLevel.Information, $"Dependency resolution completed");

