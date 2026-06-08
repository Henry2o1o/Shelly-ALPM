using System.Drawing;
using Pastel;

namespace Shelly.Cli.Interactions;

public static class Confirm
{
    public static bool Execute(string question, bool defaultValue = true)
    {
        var supportsAnsi = AnsiUtilities.SupportsAnsi;
        var defTrue = $"{"Y".Pastel(Color.Green)}/{"n".Pastel(Color.Red)}";
        var defFalse = $"{"y".Pastel(Color.Red)}/{"N".Pastel(Color.Green)}";
        var ansiHint = defaultValue ? defTrue : defFalse;
        var hint = supportsAnsi ? ansiHint : defaultValue ? "Y/n" : "y/N";
        var prompt = supportsAnsi
            ? $"{question.Pastel(Color.Orange)} {hint}"
            : $"{question} ({hint})";
        while (true)
        {
            Console.Write(prompt);
            Console.Out.Flush();
            
            var input = Console.ReadLine();
            if (string.IsNullOrWhiteSpace(input))
            {
                return defaultValue;
            }

            switch (input.Trim().ToLowerInvariant())
            {
                case "y" or "yes":
                    return true;
                case "n" or "no":
                    return false;
                default:
                    Console.WriteLine("Please answer 'y' or 'n'.");
                    break;
            }
        }
    }
}