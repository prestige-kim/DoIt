using System.Net;
using System.Net.Http.Headers;

namespace DoIt.Core;

public enum LmsSyncStatus
{
    Never,
    Ok,
    Disconnected,
    Offline,
    InvalidFeed,
    RateLimited,
    StorageError
}

public static class LmsFeedAddress
{
    public static bool TryValidate(string? text, out Uri address)
    {
        var input = text?.Trim();
        if (input is { Length: <= 4096 } && !input.Any(char.IsWhiteSpace)
            && Uri.TryCreate(input, UriKind.Absolute, out var candidate) && IsValid(candidate))
        {
            address = candidate;
            return true;
        }
        address = null!;
        return false;
    }

    internal static bool IsValid(Uri uri)
    {
        if (!uri.IsAbsoluteUri || uri.Scheme != Uri.UriSchemeHttps || string.IsNullOrEmpty(uri.Host)
            || uri.UserInfo.Length != 0 || uri.Query.Length != 0 || uri.Fragment.Length != 0)
        {
            return false;
        }
        var path = uri.AbsolutePath;
        const string marker = "/feeds/calendars/";
        int feed = path.IndexOf(marker, StringComparison.Ordinal);
        if (feed < 0 || !path.EndsWith(".ics", StringComparison.OrdinalIgnoreCase) || path.Contains('%'))
        {
            return false;
        }
        var file = path.AsSpan(feed + marker.Length);
        return file.Length > 4 && file.IndexOfAny('/', '\\') < 0;
    }

    internal static bool IsAllowedRedirect(Uri initial, Uri target) => IsValid(target)
        && initial.Port == target.Port && StringComparer.OrdinalIgnoreCase.Equals(initial.IdnHost, target.IdnHost);
}

internal sealed record LmsFeedResponse(
    LmsSyncStatus Status,
    byte[]? Body = null,
    DateTimeOffset? LastModified = null,
    TimeSpan? RetryAfter = null);

internal sealed class LmsFeedClient : IDisposable
{
    internal const int MaxFeedBytes = 5 * 1024 * 1024;
    private const int MaxRedirects = 4;
    private readonly HttpClient client;

    internal LmsFeedClient(HttpMessageHandler? testHandler)
    {
        client = new HttpClient(testHandler ?? new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            UseCookies = false,
            UseProxy = false,
            Credentials = null,
            PreAuthenticate = false,
            ActivityHeadersPropagator = null,
            AutomaticDecompression = DecompressionMethods.All,
            MaxConnectionsPerServer = 1,
            MaxResponseHeadersLength = 32
        })
        {
            Timeout = Timeout.InfiniteTimeSpan
        };
    }

    internal async Task<LmsFeedResponse> FetchAsync(Uri address, DateTimeOffset? lastModified,
        DateTimeOffset now, CancellationToken cancellationToken)
    {
        if (!LmsFeedAddress.IsValid(address))
        {
            return new(LmsSyncStatus.InvalidFeed);
        }
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        CancellationToken token = timeout.Token;
        var target = address;
        try
        {
            for (var redirects = 0; redirects <= MaxRedirects; redirects++)
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, target);
                request.Headers.Accept.ParseAdd("text/calendar");
                request.Headers.UserAgent.ParseAdd("DoIt/1.0 (personal calendar subscription)");
                request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true, NoStore = true };
                request.Headers.IfModifiedSince = lastModified;
                using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token)
                    .ConfigureAwait(false);
                int status = (int)response.StatusCode;
                if (status is 301 or 302 or 303 or 307 or 308)
                {
                    if (redirects == MaxRedirects || response.Headers.Location is not { } location
                        || !Uri.TryCreate(target, location, out var next) || !LmsFeedAddress.IsAllowedRedirect(address, next))
                    {
                        return new(LmsSyncStatus.InvalidFeed);
                    }
                    target = next;
                    continue;
                }
                return status switch
                {
                    200 => await ReadBodyAsync(response, token).ConfigureAwait(false),
                    304 => new(LmsSyncStatus.Ok),
                    401 or 403 or 404 or 410 => new(LmsSyncStatus.Disconnected),
                    429 => new(LmsSyncStatus.RateLimited, RetryAfter: ReadRetryAfter(response.Headers.RetryAfter, now)),
                    >= 500 and <= 599 => new(LmsSyncStatus.Offline),
                    _ => new(LmsSyncStatus.InvalidFeed)
                };
            }
        }
        catch (Exception error) when (error is HttpRequestException or IOException or OperationCanceledException)
        {
            return new(LmsSyncStatus.Offline);
        }
        catch (ObjectDisposedException) when (token.IsCancellationRequested)
        {
            return new(LmsSyncStatus.Offline);
        }
        return new(LmsSyncStatus.InvalidFeed);
    }

    private static TimeSpan? ReadRetryAfter(RetryConditionHeaderValue? value, DateTimeOffset now)
    {
        TimeSpan? delay = value?.Delta ?? (value?.Date is { } date ? date - now : null);
        return delay > TimeSpan.Zero ? delay : null;
    }

    private static async Task<LmsFeedResponse> ReadBodyAsync(HttpResponseMessage response, CancellationToken token)
    {
        if (response.Content.Headers.ContentLength > MaxFeedBytes)
        {
            return new(LmsSyncStatus.InvalidFeed);
        }
        using var content = new MemoryStream();
        using var input = await response.Content.ReadAsStreamAsync(token).ConfigureAwait(false);
        var chunk = new byte[16 * 1024];
        int read;
        while ((read = await input.ReadAsync(chunk, token).ConfigureAwait(false)) != 0)
        {
            if (content.Length + read > MaxFeedBytes)
            {
                return new(LmsSyncStatus.InvalidFeed);
            }
            content.Write(chunk, 0, read);
        }
        return new(LmsSyncStatus.Ok, content.ToArray(), response.Content.Headers.LastModified);
    }

    public void Dispose() => client.Dispose();
}
