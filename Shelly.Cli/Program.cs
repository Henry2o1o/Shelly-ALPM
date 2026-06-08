

using System.Reflection;
using CliFx;

return await new CommandLineApplicationBuilder()
    .SetVersion(Assembly.GetExecutingAssembly().GetName().Version?.ToString(4) ?? "unknown")
    .SetTitle("Shelly CLI")
    .SetDescription("Shelly CLI")
    .AddCommandsFromThisAssembly()
    .AllowDebugMode()
    .AllowPreviewMode()
    .Build()
    .RunAsync();