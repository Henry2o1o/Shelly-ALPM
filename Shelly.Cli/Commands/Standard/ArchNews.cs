using System.Net;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using CliFx.Binding;
using CliFx.Infrastructure;
using Pastel;
using Shelly.Cli.Models.Standard;
using Shelly.Utilities;
using Shelly.Utilities.Eventing;

namespace Shelly.Cli.Commands.Standard;

[Command("news", Description = "Show ArchLinux news")]
public partial class ArchNews : GlobalSettingsCommand
{
    [CommandOption("all", 'a', Description = "Show all news, not just news you haven't seen before.")]
    private bool All { get; set; }

    private const string ArchlinuxFeed = "https://archlinux.org/feeds/news/";


    private static readonly string FeedFolder = XdgPaths.ShellyCache("archNewsFeed");
    private static readonly string FeedPath = Path.Combine(FeedFolder, "Feed.json");

    public override async ValueTask ExecuteAsync(IConsole console)
    {
        List<RssModel> feed = await GetRssFeedAsync(ArchlinuxFeed);
        if (All)
        {
            try
            {
                if (JsonOutput)
                {
                    await OutputFeed(feed);
                }
                else if (UiMode)
                {
                    JsonPackFrame.WriteToStdout(feed);
                }
                else
                {
                    foreach (var item in feed)
                    {
                        Console.WriteLine();
                        Console.WriteLine(item.Title.Pastel(ConsoleColor.Yellow));
                        Console.WriteLine(item.PubDate.Pastel(ConsoleColor.Gray));
                        Console.WriteLine(item.Link.Pastel(ConsoleColor.Blue));
                        Console.WriteLine(item.Description.Pastel(ConsoleColor.White));
                        Console.WriteLine();
                    }
                }

                await CacheFeed(feed);
                return;
            }
            catch (Exception e)
            {
                if (UiMode)
                {
                    JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(EventLevel.Error, e.Message));
                    return;
                }

                Console.WriteLine($"Error fetching ArchLinux news: {e.Message}".Pastel(ConsoleColor.Red));
                if (Verbose)
                {
                    Console.WriteLine($"Stack trace: {e.StackTrace}".Pastel(ConsoleColor.Red));
                }

                return;
            }
        }

        var cachedFeed = await LoadCachedFeed();

        var newFeed = feed.ExceptBy(cachedFeed.Select(model => model.Link), model => model.Link).ToList();
        if (JsonOutput)
        {
            await OutputFeed(newFeed);
            if (newFeed.Count > 0)
            {
                await CacheFeed(feed);
            }

            return;
        }

        if (UiMode)
        {
            JsonPackFrame.WriteToStdout(newFeed);
            if (newFeed.Count > 0)
            {
                await CacheFeed(feed);
            }

            return;
        }

        foreach (var item in newFeed)
        {
            Console.WriteLine();
            Console.WriteLine(item.Title.Pastel(ConsoleColor.Yellow));
            Console.WriteLine(item.PubDate.Pastel(ConsoleColor.Gray));
            Console.WriteLine(item.Link.Pastel(ConsoleColor.Blue));
            Console.WriteLine(item.Description.Pastel(ConsoleColor.White));
            Console.WriteLine();
        }

        if (newFeed.Count > 0)
        {
            await CacheFeed(feed);
        }
        else
        {
            Console.WriteLine("No new news found".Pastel(ConsoleColor.Green));
        }
    }

    public override ValueTask ExecuteUiMode()
    {
        //Intentionally not implemented here. But probably should be
        throw new NotImplementedException();
    }

    private static async Task CacheFeed(List<RssModel> feed)
    {
        XdgPaths.EnsureDirectory(FeedFolder);

        var json = JsonSerializer.Serialize(feed, ShellyCliJsonContext.Default.ListRssModel);
        await File.WriteAllTextAsync(FeedPath, json);
        XdgPaths.FixOwnershipIfRoot(FeedPath);
    }

    private static async Task<List<RssModel>> LoadCachedFeed()
    {
        if (!File.Exists(FeedPath)) return [];

        try
        {
            var json = await File.ReadAllTextAsync(FeedPath);
            return JsonSerializer.Deserialize(json, ShellyCliJsonContext.Default.ListRssModel) ?? [];
        }
        catch
        {
            return [];
        }
    }

    private static async Task<List<RssModel>> GetRssFeedAsync(string url)
    {
        var xmlString = await CreateHttpClient().GetStringAsync(url);

        var xml = XDocument.Parse(xmlString);

        return xml.Descendants("item").Select(item => new RssModel(
            item.Element("title")?.Value ?? "",
            item.Element("link")?.Value ?? "",
            HtmlToMarkdown.Convert(item.Element("description")?.Value ?? ""),
            item.Element("pubDate")?.Value ?? "")).Reverse().ToList();
    }

    private async Task OutputFeed(List<RssModel> feed)
    {
        var json = JsonSerializer.Serialize(feed, ShellyCliJsonContext.Default.ListRssModel);
        await using var stdout = Console.OpenStandardOutput();
        await using var writer = new StreamWriter(stdout, Encoding.UTF8);
        await writer.WriteLineAsync(json);
        await writer.FlushAsync();
    }

    private static HttpClient CreateHttpClient()
    {
        return new HttpClient(new SocketsHttpHandler
        {
            AutomaticDecompression = DecompressionMethods.All,
            AllowAutoRedirect = true,
            MaxAutomaticRedirections = 10,
            ConnectTimeout = TimeSpan.FromSeconds(30),
            EnableMultipleHttp2Connections = true,
            EnableMultipleHttp3Connections = true
        })
        {
            Timeout = TimeSpan.FromMinutes(1),
            DefaultRequestHeaders = { UserAgent = { Http.UserAgent } },
            DefaultRequestVersion = HttpVersion.Version11,
            DefaultVersionPolicy = HttpVersionPolicy.RequestVersionOrHigher
        };
    }
}