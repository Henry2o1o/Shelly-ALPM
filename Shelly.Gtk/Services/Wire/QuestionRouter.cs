using Shelly.Gtk.Helpers;
using Shelly.Utilities.Eventing;

namespace Shelly.Gtk.Services.Wire;

internal static class QuestionRouter
{
    public static async Task<bool> TryDispatchAsync(string base64, Func<string,
            Task> writeFrame, 
        Func<PkgbuildDiffQuestionDto,
        Task<bool>>askPkgbuildDiff)    
    {
        if (!JsonPackFrame.TryDecodePayload<QuestionRequest>(base64, out var req) || req is null)
            return false;

        QuestionResponseDto resp = req switch
        {
            PkgbuildDiffQuestionDto d => new PkgbuildDiffAnswer(d.QuestionId, 
                await askPkgbuildDiff(d)),
            _ => throw new InvalidOperationException($"Unhandled QuestionRequest {req.GetType()}")
        };

        var frame = JsonPackFrame.EncodeFrame<QuestionResponseDto>(resp);
        await writeFrame(frame);
        return true;
    }
}
