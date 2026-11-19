using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace DoIt.Core;

// x.y.z only: three decimal parts, no sign, no leading zeros, each at most 65535 (a Windows file version part).
public readonly record struct AppVersion(int Major, int Minor, int Patch) : IComparable<AppVersion>
{
    public static bool TryParse(string? text, out AppVersion version)
    {
        version = default;
        var parts = text?.Split('.');
        if (parts is not { Length: 3 })
        {
            return false;
        }
        var values = new int[3];
        for (int i = 0; i < 3; i++)
        {
            string part = parts[i];
            if (part.Length is 0 or > 5 || (part.Length > 1 && part[0] == '0') || !part.All(char.IsAsciiDigit)
                || !int.TryParse(part, NumberStyles.None, CultureInfo.InvariantCulture, out values[i]) || values[i] > 65535)
            {
                return false;
            }
        }
        version = new AppVersion(values[0], values[1], values[2]);
        return true;
    }

    public int CompareTo(AppVersion other)
    {
        int result = Major.CompareTo(other.Major);
        if (result == 0) result = Minor.CompareTo(other.Minor);
        return result == 0 ? Patch.CompareTo(other.Patch) : result;
    }

    public override string ToString() => $"{Major}.{Minor}.{Patch}";
}

public sealed record UpdateAsset(Uri Url, string Sha256);

public sealed record UpdateRelease(AppVersion Version, int Build, IReadOnlyDictionary<string, UpdateAsset> Assets)
{
    public bool IsNewerThan(AppVersion version, int build)
    {
        int compared = Version.CompareTo(version);
        return compared > 0 || (compared == 0 && Build > build);
    }

    public UpdateAsset? AssetFor(string? architecture) =>
        architecture is not null && Assets.TryGetValue(architecture, out var asset) ? asset : null;
}

// Published is false for {"schemaVersion":1,"releasePublished":false}; Release is then null.
public sealed record UpdateManifest(bool Published, UpdateRelease? Release);

public static class UpdateManifestParser
{
    public const string FeedAddress = "https://prestige-kim.github.io/DoIt/windows-release.json";
    public const int SchemaVersion = 1;
    public const int MaxBuild = 65535;
    public static readonly IReadOnlyList<string> Architectures = ["x64", "arm64"];

    private static readonly JsonDocumentOptions Options = new() { MaxDepth = 8, AllowDuplicateProperties = false };

    public static string ExpectedAssetUrl(AppVersion version, int build, string architecture) =>
        $"https://github.com/prestige-kim/DoIt/releases/download/windows-v{version}-{build}/DoIt-Windows-{version}-{build}-{architecture}-Setup.exe";

    public static UpdateManifest? Parse(byte[] json)
    {
        try
        {
            using var document = JsonDocument.Parse(json, Options);
            return Parse(document.RootElement);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    internal static UpdateManifest? Parse(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object
            || !root.TryGetProperty("schemaVersion", out var schema) || schema.ValueKind != JsonValueKind.Number
            || !schema.TryGetInt32(out int schemaVersion) || schemaVersion != SchemaVersion
            || !root.TryGetProperty("releasePublished", out var published)
            || published.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            return null;
        }
        if (published.ValueKind == JsonValueKind.False)
        {
            return new UpdateManifest(false, null);
        }
        if (!root.TryGetProperty("version", out var versionText) || versionText.ValueKind != JsonValueKind.String
            || !AppVersion.TryParse(versionText.GetString(), out var version)
            || !root.TryGetProperty("build", out var buildValue) || buildValue.ValueKind != JsonValueKind.Number
            || !buildValue.TryGetInt32(out int build) || build is < 1 or > MaxBuild
            || !root.TryGetProperty("assets", out var assetList) || assetList.ValueKind != JsonValueKind.Object)
        {
            return null;
        }
        var assets = new Dictionary<string, UpdateAsset>(StringComparer.Ordinal);
        foreach (var property in assetList.EnumerateObject())
        {
            if (!Architectures.Contains(property.Name))
            {
                // A later site may list more architectures. Older apps ignore them.
                continue;
            }
            var asset = ParseAsset(property.Value, version, build, property.Name);
            if (asset is null)
            {
                return null;
            }
            assets[property.Name] = asset;
        }
        return assets.Count == 0 ? null : new UpdateManifest(true, new UpdateRelease(version, build, assets));
    }

    private static UpdateAsset? ParseAsset(JsonElement value, AppVersion version, int build, string architecture)
    {
        if (value.ValueKind != JsonValueKind.Object
            || !value.TryGetProperty("url", out var url) || url.ValueKind != JsonValueKind.String
            || !value.TryGetProperty("sha256", out var hash) || hash.ValueKind != JsonValueKind.String)
        {
            return null;
        }
        string expected = ExpectedAssetUrl(version, build, architecture);
        string? sha = hash.GetString();
        if (!string.Equals(url.GetString(), expected, StringComparison.Ordinal)
            || sha is not { Length: 64 } || !sha.All(char.IsAsciiHexDigit)
            || !Uri.TryCreate(expected, UriKind.Absolute, out var address))
        {
            return null;
        }
        return new UpdateAsset(address, sha.ToLowerInvariant());
    }

    internal static void Write(Utf8JsonWriter writer, UpdateRelease? release)
    {
        writer.WriteStartObject();
        writer.WriteNumber("schemaVersion", SchemaVersion);
        writer.WriteBoolean("releasePublished", release is not null);
        if (release is not null)
        {
            writer.WriteString("version", release.Version.ToString());
            writer.WriteNumber("build", release.Build);
            writer.WriteStartObject("assets");
            foreach (string architecture in Architectures)
            {
                if (release.Assets.TryGetValue(architecture, out var asset))
                {
                    writer.WriteStartObject(architecture);
                    writer.WriteString("url", asset.Url.OriginalString);
                    writer.WriteString("sha256", asset.Sha256);
                    writer.WriteEndObject();
                }
            }
            writer.WriteEndObject();
        }
        writer.WriteEndObject();
    }
}

public static class UpdateSchedule
{
    public static readonly TimeSpan AutomaticInterval = TimeSpan.FromHours(24);
    public static readonly TimeSpan ManualDebounce = TimeSpan.FromMinutes(1);
    // After a failed attempt (offline at boot, server error) the next event may retry sooner than a day.
    public static readonly TimeSpan FailedRetryInterval = TimeSpan.FromHours(1);

    // A last attempt in the future means the clock moved back, so the next event may check again.
    public static bool IsDue(DateTimeOffset? lastAttempt, DateTimeOffset now, bool manual, bool lastFailed = false)
    {
        if (lastAttempt is not { } last)
        {
            return true;
        }
        var elapsed = now - last;
        var interval = manual ? ManualDebounce : lastFailed ? FailedRetryInterval : AutomaticInterval;
        return elapsed < TimeSpan.Zero || elapsed >= interval;
    }

    public static string? CurrentArchitecture() => RuntimeInformation.ProcessArchitecture switch
    {
        Architecture.X64 => "x64",
        Architecture.Arm64 => "arm64",
        _ => null
    };
}

public enum UpdateCheckResult
{
    Ok,
    Offline,
    Unavailable,
    Invalid
}

public sealed record UpdateSnapshot(
    bool IsDevelopmentBuild,
    bool AutoCheck,
    bool IsChecking,
    DateTimeOffset? LastAttemptAt,
    DateTimeOffset? LastSuccessAt,
    UpdateCheckResult? LastResult,
    UpdateRelease? Latest,
    UpdateRelease? Available,
    Uri? DownloadUrl);

public static class UpdateDisplay
{
    public static string Status(UpdateSnapshot snapshot)
    {
        if (snapshot.IsDevelopmentBuild)
        {
            return "개발 빌드라 새 버전을 확인하지 않습니다.";
        }
        if (snapshot.IsChecking)
        {
            return "새 버전을 확인하는 중입니다…";
        }
        if (snapshot.Available is { } available)
        {
            string label = $"새 버전 {available.Version} (빌드 {available.Build})이 있습니다.";
            return snapshot.DownloadUrl is null ? label + " 이 PC에 맞는 설치 파일은 아직 없습니다." : label;
        }
        return snapshot.LastResult switch
        {
            UpdateCheckResult.Ok => snapshot.Latest is null ? "아직 공개된 새 버전이 없습니다." : "최신 버전입니다.",
            UpdateCheckResult.Offline => "새 버전을 확인하지 못했습니다. 인터넷 연결을 확인한 뒤 다시 시도해 주세요.",
            UpdateCheckResult.Unavailable => "새 버전 정보를 받을 수 없습니다. 나중에 다시 시도해 주세요.",
            UpdateCheckResult.Invalid => "새 버전 정보를 읽지 못했습니다. 나중에 다시 시도해 주세요.",
            _ => "아직 새 버전을 확인하지 않았습니다."
        };
    }

    public static string LastChecked(UpdateSnapshot snapshot, TimeZoneInfo zone)
    {
        if (snapshot.IsDevelopmentBuild || snapshot.LastSuccessAt is not { } success)
        {
            return "";
        }
        var local = TimeZoneInfo.ConvertTime(success, zone);
        return $"마지막 확인 {local.ToString("M월 d일 H:mm", CultureInfo.InvariantCulture)}";
    }

    public static string? MenuLabel(UpdateSnapshot snapshot) =>
        snapshot is { Available: { } available, DownloadUrl: not null } ? $"새 버전 받기 ({available.Version})" : null;
}

public sealed class UpdateService : IDisposable
{
    public const string StateFileName = "update-check.json";
    private const int MaxStateBytes = 64 * 1024;
    private readonly object gate = new();
    private readonly string path;
    private readonly AppVersion current;
    private readonly int currentBuild;
    private readonly string? architecture;
    private readonly bool development;
    private readonly TimeProvider clock;
    private readonly UpdateFeedClient client;
    private readonly CancellationTokenSource lifetime = new();
    private State state;
    private bool checking;
    private bool disposed;

    // version and build come from the app's assembly. A build of 0 or a version that is not x.y.z is a
    // development build, which never contacts the network.
    public UpdateService(string directory, string? version, int build, string? architecture,
        HttpMessageHandler? handler = null, TimeProvider? clock = null, TimeSpan? requestTimeout = null)
    {
        path = Path.Combine(Path.GetFullPath(directory), StateFileName);
        development = build is < 1 or > UpdateManifestParser.MaxBuild || !AppVersion.TryParse(version, out current);
        currentBuild = build;
        this.architecture = architecture;
        this.clock = clock ?? TimeProvider.System;
        client = new UpdateFeedClient(handler, requestTimeout ?? TimeSpan.FromSeconds(15));
        state = Load(path);
    }

    public event Action? Changed;

    public UpdateSnapshot Snapshot
    {
        get
        {
            lock (gate)
            {
                var available = !development && state.Release is { } release && release.IsNewerThan(current, currentBuild)
                    ? release
                    : null;
                return new UpdateSnapshot(development, state.AutoCheck, checking, state.LastAttemptAt, state.LastSuccessAt,
                    state.LastResult, state.Release, available, available?.AssetFor(architecture)?.Url);
            }
        }
    }

    public bool SetAutoCheck(bool enabled)
    {
        lock (gate)
        {
            if (disposed) return false;
            var next = state with { AutoCheck = enabled };
            if (!TrySave(next)) return false;
            state = next;
        }
        Changed?.Invoke();
        return true;
    }

    // Returns false when the check was skipped: development build, already checking, automatic checks off,
    // or the last attempt was too recent (24 hours automatic, 1 hour after a failure, 1 minute manual).
    public async Task<bool> CheckAsync(bool manual)
    {
        DateTimeOffset now;
        CancellationToken token;
        lock (gate)
        {
            now = clock.GetUtcNow();
            if (disposed || development || checking || (!manual && !state.AutoCheck)
                || !UpdateSchedule.IsDue(state.LastAttemptAt, now, manual,
                    lastFailed: state.LastResult is { } last && last != UpdateCheckResult.Ok))
            {
                return false;
            }
            checking = true;
            token = lifetime.Token;
        }
        Changed?.Invoke();

        var (result, body) = await client.FetchAsync(current.ToString(), token).ConfigureAwait(false);
        UpdateManifest? manifest = null;
        if (result == UpdateCheckResult.Ok && body is not null)
        {
            manifest = UpdateManifestParser.Parse(body);
            if (manifest is null) result = UpdateCheckResult.Invalid;
        }

        lock (gate)
        {
            checking = false;
            if (disposed)
            {
                return true;
            }
            var next = state with { LastAttemptAt = now, LastResult = result };
            if (manifest is not null)
            {
                next = next with { LastSuccessAt = clock.GetUtcNow(), Release = manifest.Release };
            }
            TrySave(next);
            // Keep the result in memory even when the small state file can't be written.
            state = next;
        }
        Changed?.Invoke();
        return true;
    }

    private bool TrySave(State value)
    {
        try
        {
            using var buffer = new MemoryStream();
            using (var writer = new Utf8JsonWriter(buffer))
            {
                writer.WriteStartObject();
                writer.WriteNumber("schemaVersion", 1);
                writer.WriteBoolean("autoCheck", value.AutoCheck);
                if (value.LastAttemptAt is { } attempt) writer.WriteString("lastAttemptAt", attempt.ToUniversalTime());
                if (value.LastSuccessAt is { } success) writer.WriteString("lastSuccessAt", success.ToUniversalTime());
                if (value.LastResult is { } result) writer.WriteString("lastResult", result.ToString());
                if (value.LastSuccessAt is not null)
                {
                    writer.WritePropertyName("release");
                    UpdateManifestParser.Write(writer, value.Release);
                }
                writer.WriteEndObject();
            }
            LmsLocalFile.WriteAtomic(path, buffer.ToArray());
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    // A missing file is a first run (automatic checks on). A file that can't be read is treated as
    // "automatic checks off" so a damaged file never turns network access back on by itself.
    private static State Load(string path)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists) return new State(true, null, null, null, null);
            if (info.Length > MaxStateBytes) return State.Unreadable;
            using var document = JsonDocument.Parse(File.ReadAllBytes(path),
                new JsonDocumentOptions { MaxDepth = 10, AllowDuplicateProperties = false });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("schemaVersion", out var schema) || schema.ValueKind != JsonValueKind.Number
                || !schema.TryGetInt32(out int version) || version != 1
                || !root.TryGetProperty("autoCheck", out var auto) || auto.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
            {
                return State.Unreadable;
            }
            var loaded = new State(auto.GetBoolean(), ReadTime(root, "lastAttemptAt"), ReadTime(root, "lastSuccessAt"),
                root.TryGetProperty("lastResult", out var result) && result.ValueKind == JsonValueKind.String
                    && Enum.TryParse<UpdateCheckResult>(result.GetString(), ignoreCase: false, out var parsed)
                    && Enum.IsDefined(parsed) ? parsed : null,
                null);
            if (loaded.LastSuccessAt is not null && root.TryGetProperty("release", out var release))
            {
                // The stored release passes the same checks as the downloaded file, so an edited file can't
                // point the download button somewhere else.
                if (UpdateManifestParser.Parse(release) is { } manifest)
                {
                    loaded = loaded with { Release = manifest.Release };
                }
                else
                {
                    loaded = loaded with { LastSuccessAt = null, LastResult = null };
                }
            }
            return loaded;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            return State.Unreadable;
        }
    }

    private static DateTimeOffset? ReadTime(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            && value.TryGetDateTimeOffset(out var time) ? time : null;

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
        }
        lifetime.Cancel();
        lifetime.Dispose();
        client.Dispose();
    }

    private sealed record State(bool AutoCheck, DateTimeOffset? LastAttemptAt, DateTimeOffset? LastSuccessAt,
        UpdateCheckResult? LastResult, UpdateRelease? Release)
    {
        internal static State Unreadable => new(false, null, null, null, null);
    }
}

internal sealed class UpdateFeedClient : IDisposable
{
    internal const int MaxBytes = 64 * 1024;
    private const int MaxRedirects = 4;
    private static readonly Uri Address = new(UpdateManifestParser.FeedAddress);
    private readonly HttpClient client;
    private readonly TimeSpan timeout;

    internal UpdateFeedClient(HttpMessageHandler? testHandler, TimeSpan timeout)
    {
        this.timeout = timeout;
        // Same principles as the LMS client: no cookies, credentials or proxy, and redirects are checked here.
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

    internal static bool IsAllowedRedirect(Uri target) => target.IsAbsoluteUri && target.Scheme == Uri.UriSchemeHttps
        && target.UserInfo.Length == 0 && target.Port == Address.Port
        && StringComparer.OrdinalIgnoreCase.Equals(target.IdnHost, Address.IdnHost);

    internal async Task<(UpdateCheckResult Result, byte[]? Body)> FetchAsync(string version, CancellationToken cancellationToken)
    {
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        limit.CancelAfter(timeout);
        var token = limit.Token;
        var target = Address;
        try
        {
            for (int redirects = 0; redirects <= MaxRedirects; redirects++)
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, target);
                request.Headers.Accept.ParseAdd("application/json");
                request.Headers.UserAgent.Add(new ProductInfoHeaderValue("DoIt-Windows", version));
                request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true };
                using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token)
                    .ConfigureAwait(false);
                int status = (int)response.StatusCode;
                if (status is 301 or 302 or 303 or 307 or 308)
                {
                    if (redirects == MaxRedirects || response.Headers.Location is not { } location
                        || !Uri.TryCreate(target, location, out var next) || !IsAllowedRedirect(next))
                    {
                        return (UpdateCheckResult.Invalid, null);
                    }
                    target = next;
                    continue;
                }
                return status == 200
                    ? await ReadBodyAsync(response, token).ConfigureAwait(false)
                    : (UpdateCheckResult.Unavailable, null);
            }
        }
        catch (Exception error) when (error is HttpRequestException or IOException or OperationCanceledException)
        {
            return (UpdateCheckResult.Offline, null);
        }
        catch (ObjectDisposedException) when (token.IsCancellationRequested)
        {
            return (UpdateCheckResult.Offline, null);
        }
        return (UpdateCheckResult.Invalid, null);
    }

    private static async Task<(UpdateCheckResult, byte[]?)> ReadBodyAsync(HttpResponseMessage response, CancellationToken token)
    {
        if (response.Content.Headers.ContentLength > MaxBytes)
        {
            return (UpdateCheckResult.Invalid, null);
        }
        using var content = new MemoryStream();
        using var input = await response.Content.ReadAsStreamAsync(token).ConfigureAwait(false);
        var chunk = new byte[8 * 1024];
        int read;
        while ((read = await input.ReadAsync(chunk, token).ConfigureAwait(false)) != 0)
        {
            if (content.Length + read > MaxBytes)
            {
                return (UpdateCheckResult.Invalid, null);
            }
            content.Write(chunk, 0, read);
        }
        return (UpdateCheckResult.Ok, content.ToArray());
    }

    public void Dispose() => client.Dispose();
}
