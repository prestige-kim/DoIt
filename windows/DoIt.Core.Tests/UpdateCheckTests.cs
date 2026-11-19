using System.Net;
using System.Net.Http.Headers;
using System.Text;
using DoIt.Core;

internal static class UpdateCheckTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 18, 9, 0, 0, TimeSpan.Zero);
    private static readonly string Hash = new('a', 64);
    private const string Current = "1.0.2";
    private const int CurrentBuild = 3;

    internal static IEnumerable<(string Name, Action Run)> Cases =>
    [
        ("Update manifest parses a published release with both architectures", ParsePublished),
        ("Update manifest accepts the unpublished placeholder", ParseUnpublished),
        ("Update manifest rejects a wrong schema, JSON shape or duplicate field", RejectSchema),
        ("Update manifest rejects malformed versions and builds", RejectVersionAndBuild),
        ("Update manifest accepts only the exact GitHub Releases URL for each architecture", RejectUrls),
        ("Update manifest requires a 64-digit hex sha256", RejectHashes),
        ("Update comparison uses the version first and then the build", CompareVersions),
        ("Update picks the current architecture and reports a missing installer", ChooseArchitecture),
        ("Update interval is 24 hours automatic and 1 minute manual", Schedule),
        ("Update check sends one GET with only the app version as user agent", RequestShape),
        ("Update service skips repeated checks and keeps the result across restart", ServiceIntervals),
        ("Update service never checks a development build or with automatic checks off", DevelopmentAndOff),
        ("Update service treats a damaged state file as automatic checks off", DamagedState),
        ("Update service ignores a stored release with an edited download URL", TamperedState),
        ("Update request caps advertised and streamed response sizes", BoundResponse),
        ("Update request follows only same-host HTTPS redirects", Redirects),
        ("Update request reports 404, server errors, network errors and timeouts as failures", Failures),
        ("Update failure keeps the last known release", FailureKeepsRelease),
    ];

    private static string Url(string version, int build, string arch) =>
        $"https://github.com/prestige-kim/DoIt/releases/download/windows-v{version}-{build}/DoIt-Windows-{version}-{build}-{arch}-Setup.exe";

    private static string Asset(string url, string? hash = null) => $$"""{"url":"{{url}}","sha256":"{{hash ?? Hash}}"}""";

    private static string X64(string asset) => "{\"x64\":" + asset + "}";

    private static string Manifest(string version = "1.0.3", string build = "4", string? assets = null)
    {
        int number = int.TryParse(build, out var parsed) ? parsed : 0;
        assets ??= "{\"x64\":" + Asset(Url(version, number, "x64")) + ",\"arm64\":" + Asset(Url(version, number, "arm64")) + "}";
        return "{\"schemaVersion\":1,\"releasePublished\":true,\"version\":\"" + version + "\",\"build\":" + build
            + ",\"assets\":" + assets + "}";
    }

    private static UpdateManifest? Parse(string json) => UpdateManifestParser.Parse(Encoding.UTF8.GetBytes(json));

    private static void ParsePublished()
    {
        var manifest = Parse(Manifest()) ?? throw new InvalidOperationException("parse failed");
        Equal(true, manifest.Published);
        var release = manifest.Release!;
        Equal(new AppVersion(1, 0, 3), release.Version);
        Equal(4, release.Build);
        Equal(Url("1.0.3", 4, "arm64"), release.AssetFor("arm64")!.Url.OriginalString);
        Equal(Hash, release.AssetFor("x64")!.Sha256);
        // Unknown extra fields and architectures are ignored for forward compatibility.
        var extra = Parse(Manifest(assets: "{\"x64\":" + Asset(Url("1.0.3", 4, "x64")) + ",\"riscv\":{\"url\":\"x\"}}"));
        Equal(1, extra!.Release!.Assets.Count);
    }

    private static void ParseUnpublished()
    {
        var manifest = Parse("""{"schemaVersion":1,"releasePublished":false}""");
        Equal(false, manifest!.Published);
        Equal<UpdateRelease?>(null, manifest.Release);
    }

    private static void RejectSchema()
    {
        foreach (string json in new[]
        {
            "", "null", "[]", "not json", """{"releasePublished":false}""", """{"schemaVersion":2,"releasePublished":false}""",
            """{"schemaVersion":"1","releasePublished":false}""", """{"schemaVersion":1.5,"releasePublished":false}""",
            """{"schemaVersion":1,"releasePublished":"false"}""", """{"schemaVersion":1}""",
            """{"schemaVersion":1,"releasePublished":false,"releasePublished":true}""",
            """{"schemaVersion":1,"releasePublished":true,"version":"1.0.3","build":4}""",
            """{"schemaVersion":1,"releasePublished":true,"version":"1.0.3","build":4,"assets":{}}""",
            """{"schemaVersion":1,"releasePublished":true,"version":"1.0.3","build":4,"assets":[]}""",
            Manifest(assets: """{"x64":"https://example.invalid"}"""),
            Manifest(assets: "{\"x64\":{\"url\":\"" + Url("1.0.3", 4, "x64") + "\"}}"),
        })
        {
            Equal<UpdateManifest?>(null, Parse(json));
        }
    }

    private static void RejectVersionAndBuild()
    {
        foreach (string version in new[] { "1.0", "1.0.0.0", "01.0.0", "1.0.x", "-1.0.0", " 1.0.0", "1.0.0-beta", "1..0", "65536.0.0", "１.0.0" })
        {
            Equal(false, AppVersion.TryParse(version, out _));
            Equal<UpdateManifest?>(null, Parse(Manifest(version: version)));
        }
        Equal(true, AppVersion.TryParse("0.10.65535", out var parsed));
        Equal(new AppVersion(0, 10, 65535), parsed);
        foreach (string build in new[] { "0", "-1", "65536", "4.5", "\"4\"", "null" })
        {
            Equal<UpdateManifest?>(null, Parse(Manifest(build: build, assets: X64(Asset(Url("1.0.3", 4, "x64"))))));
        }
        Equal(true, Parse(Manifest(build: "65535")) is not null);
    }

    private static void RejectUrls()
    {
        string good = Url("1.0.3", 4, "x64");
        foreach (string url in new[]
        {
            good.Replace("https://github.com", "https://example.invalid"),
            good.Replace("https://", "http://"),
            good.Replace("prestige-kim/DoIt", "someone/DoIt"),
            good.Replace("windows-v1.0.3-4/", "windows-v1.0.2-4/"),
            good.Replace("windows-v1.0.3-4/", "v1.0.3/"),
            good.Replace("DoIt-Windows-1.0.3-4-x64-Setup.exe", "DoIt-Windows-1.0.3-4-x64.exe"),
            good.Replace("-Setup.exe", "-Setup.exe.zip"),
            good + "?download=1",
            good.Replace("github.com", "GITHUB.com"),
            Url("1.0.3", 4, "arm64"),
        })
        {
            Equal<UpdateManifest?>(null, Parse(Manifest(assets: X64(Asset(url)))));
        }
    }

    private static void RejectHashes()
    {
        foreach (string hash in new[] { new string('a', 63), new string('a', 65), new string('g', 64), "", new string('a', 62) + "  " })
        {
            Equal<UpdateManifest?>(null, Parse(Manifest(assets: X64(Asset(Url("1.0.3", 4, "x64"), hash)))));
        }
        var upper = Parse(Manifest(assets: X64(Asset(Url("1.0.3", 4, "x64"), new string('A', 64)))));
        Equal(Hash, upper!.Release!.AssetFor("x64")!.Sha256);
    }

    private static void CompareVersions()
    {
        var release = Parse(Manifest())!.Release!;
        Equal(false, release.IsNewerThan(new AppVersion(1, 0, 3), 4));
        Equal(false, release.IsNewerThan(new AppVersion(1, 0, 3), 5));
        Equal(false, release.IsNewerThan(new AppVersion(1, 1, 0), 1));
        Equal(false, release.IsNewerThan(new AppVersion(2, 0, 0), 1));
        Equal(true, release.IsNewerThan(new AppVersion(1, 0, 3), 3));
        Equal(true, release.IsNewerThan(new AppVersion(1, 0, 2), 9));
        Equal(true, release.IsNewerThan(new AppVersion(0, 9, 9), 100));
        Equal(true, new AppVersion(1, 10, 0).CompareTo(new AppVersion(1, 9, 9)) > 0);
    }

    private static void ChooseArchitecture() => WithTemp(async directory =>
    {
        string x64Only = Manifest(assets: X64(Asset(Url("1.0.3", 4, "x64"))));
        using (var arm = Service(Path.Combine(directory, "arm"), out _, (_, _) => Json(x64Only), architecture: "arm64"))
        {
            await arm.CheckAsync(manual: false);
            var snapshot = arm.Snapshot;
            Equal(new AppVersion(1, 0, 3), snapshot.Available!.Version);
            Equal<Uri?>(null, snapshot.DownloadUrl);
            Equal<string?>(null, UpdateDisplay.MenuLabel(snapshot));
            Equal(true, UpdateDisplay.Status(snapshot).Contains("설치 파일은 아직 없습니다", StringComparison.Ordinal));
        }
        using var x64 = Service(Path.Combine(directory, "x64"), out _, (_, _) => Json(Manifest()), architecture: "x64");
        await x64.CheckAsync(manual: false);
        Equal(Url("1.0.3", 4, "x64"), x64.Snapshot.DownloadUrl!.OriginalString);
        Equal("새 버전 받기 (1.0.3)", UpdateDisplay.MenuLabel(x64.Snapshot));
        Equal("새 버전 1.0.3 (빌드 4)이 있습니다.", UpdateDisplay.Status(x64.Snapshot));
        using var unknown = Service(Path.Combine(directory, "unknown"), out _, (_, _) => Json(Manifest()), architecture: null);
        await unknown.CheckAsync(manual: false);
        Equal<Uri?>(null, unknown.Snapshot.DownloadUrl);
    });

    private static void Schedule()
    {
        Equal(true, UpdateSchedule.IsDue(null, Now, manual: false));
        Equal(false, UpdateSchedule.IsDue(Now.AddHours(-23).AddMinutes(-59), Now, manual: false));
        Equal(true, UpdateSchedule.IsDue(Now.AddHours(-24), Now, manual: false));
        Equal(false, UpdateSchedule.IsDue(Now.AddSeconds(-59), Now, manual: true));
        Equal(true, UpdateSchedule.IsDue(Now.AddMinutes(-1), Now, manual: true));
        Equal(true, UpdateSchedule.IsDue(Now.AddHours(1), Now, manual: false));
        // A failed attempt retries after an hour instead of a day; a manual check keeps the 1-minute debounce.
        Equal(false, UpdateSchedule.IsDue(Now.AddMinutes(-59), Now, manual: false, lastFailed: true));
        Equal(true, UpdateSchedule.IsDue(Now.AddHours(-1), Now, manual: false, lastFailed: true));
        Equal(false, UpdateSchedule.IsDue(Now.AddSeconds(-30), Now, manual: true, lastFailed: true));
    }

    private static void RequestShape() => WithTemp(async directory =>
    {
        using var service = Service(directory, out var handler, (request, _) =>
        {
            Equal(HttpMethod.Get, request.Method);
            Equal(UpdateManifestParser.FeedAddress, request.RequestUri!.AbsoluteUri);
            Equal<HttpContent?>(null, request.Content);
            Equal<AuthenticationHeaderValue?>(null, request.Headers.Authorization);
            Equal(false, request.Headers.Contains("Cookie"));
            Equal("DoIt-Windows/1.0.2", request.Headers.UserAgent.ToString());
            return Json(Manifest());
        });
        Equal(true, await service.CheckAsync(manual: false));
        Equal(1, handler.Count);
        string saved = File.ReadAllText(Path.Combine(directory, UpdateService.StateFileName));
        Equal(false, saved.Contains("DoIt-Windows/", StringComparison.Ordinal));
    });

    private static void ServiceIntervals() => WithTemp(async directory =>
    {
        var clock = new FakeClock();
        using (var first = Service(directory, out var handler, (_, _) => Json(Manifest()), clock: clock))
        {
            Equal(true, await first.CheckAsync(manual: false));
            Equal(false, await first.CheckAsync(manual: false));
            Equal(false, await first.CheckAsync(manual: true));
            clock.UtcNow = Now.AddMinutes(1);
            Equal(true, await first.CheckAsync(manual: true));
            Equal(2, handler.Count);
        }
        clock.UtcNow = Now.AddHours(23);
        using (var restarted = Service(directory, out var handler, (_, _) => Json(Manifest()), clock: clock))
        {
            Equal(false, await restarted.CheckAsync(manual: false));
            Equal(0, handler.Count);
            Equal(new AppVersion(1, 0, 3), restarted.Snapshot.Available!.Version);
            Equal(Now.AddMinutes(1), restarted.Snapshot.LastSuccessAt);
            Equal("마지막 확인 11월 18일 9:01", UpdateDisplay.LastChecked(restarted.Snapshot, TimeZoneInfo.Utc));
            clock.UtcNow = Now.AddMinutes(1).AddHours(24);
            Equal(true, await restarted.CheckAsync(manual: false));
            Equal(1, handler.Count);
        }
        // After installing the new version the same stored release is no longer "new".
        using var updated = new UpdateService(directory, "1.0.3", 4, "x64", new FakeHandler((_, _) => Task.FromResult(Json(Manifest()))), clock);
        Equal<UpdateRelease?>(null, updated.Snapshot.Available);
        Equal("최신 버전입니다.", UpdateDisplay.Status(updated.Snapshot));
    });

    private static void DevelopmentAndOff() => WithTemp(async directory =>
    {
        foreach (var (version, build) in new[] { ("1.0.2", 0), ("1.0", 3), ((string?)null, 3), ("1.0.2", 70000) })
        {
            var handler = new FakeHandler((_, _) => Task.FromResult(Json(Manifest())));
            using var dev = new UpdateService(Path.Combine(directory, "dev"), version, build, "x64", handler, new FakeClock());
            Equal(false, await dev.CheckAsync(manual: true));
            Equal(0, handler.Count);
            Equal("개발 빌드라 새 버전을 확인하지 않습니다.", UpdateDisplay.Status(dev.Snapshot));
        }
        using var off = Service(Path.Combine(directory, "off"), out var offHandler, (_, _) => Json(Manifest()));
        Equal(true, off.Snapshot.AutoCheck);
        Equal("아직 새 버전을 확인하지 않았습니다.", UpdateDisplay.Status(off.Snapshot));
        Equal(true, off.SetAutoCheck(false));
        Equal(false, await off.CheckAsync(manual: false));
        Equal(0, offHandler.Count);
        Equal(true, await off.CheckAsync(manual: true));
        Equal(1, offHandler.Count);
        using var reopened = Service(Path.Combine(directory, "off"), out _, (_, _) => Json(Manifest()));
        Equal(false, reopened.Snapshot.AutoCheck);
    });

    private static void DamagedState() => WithTemp(async directory =>
    {
        File.WriteAllText(Path.Combine(directory, UpdateService.StateFileName), "{broken");
        using var service = Service(directory, out var handler, (_, _) => Json(Manifest()));
        Equal(false, service.Snapshot.AutoCheck);
        Equal(false, await service.CheckAsync(manual: false));
        Equal(0, handler.Count);
        Equal(true, service.SetAutoCheck(true));
        Equal(true, await service.CheckAsync(manual: false));
        Equal(1, handler.Count);
    });

    private static void TamperedState() => WithTemp(async directory =>
    {
        using (var first = Service(directory, out _, (_, _) => Json(Manifest())))
        {
            await first.CheckAsync(manual: false);
        }
        string path = Path.Combine(directory, UpdateService.StateFileName);
        File.WriteAllText(path, File.ReadAllText(path).Replace("https://github.com", "https://example.invalid"));
        using var reopened = Service(directory, out _, (_, _) => Json(Manifest()));
        Equal<UpdateRelease?>(null, reopened.Snapshot.Available);
        Equal<Uri?>(null, reopened.Snapshot.DownloadUrl);
        Equal(true, reopened.Snapshot.AutoCheck);
    });

    private static void BoundResponse() => WithTemp(async directory =>
    {
        using (var declared = Service(Path.Combine(directory, "declared"), out _, (_, _) =>
        {
            var content = new StringContent("{}");
            content.Headers.ContentLength = 64 * 1024 + 1;
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = content };
        }))
        {
            await declared.CheckAsync(manual: false);
            Equal<UpdateCheckResult?>(UpdateCheckResult.Invalid, declared.Snapshot.LastResult);
        }
        using (var streamed = Service(Path.Combine(directory, "streamed"), out _, (_, _) =>
            new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new NonSeekableStream(new byte[64 * 1024 + 1])) }))
        {
            await streamed.CheckAsync(manual: false);
            Equal<UpdateCheckResult?>(UpdateCheckResult.Invalid, streamed.Snapshot.LastResult);
            Equal("새 버전 정보를 읽지 못했습니다. 나중에 다시 시도해 주세요.", UpdateDisplay.Status(streamed.Snapshot));
        }
        string padded = Manifest().PadRight(64 * 1024);
        using var exact = Service(Path.Combine(directory, "exact"), out _, (_, _) =>
            new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new NonSeekableStream(Encoding.UTF8.GetBytes(padded))) });
        await exact.CheckAsync(manual: false);
        Equal<UpdateCheckResult?>(UpdateCheckResult.Ok, exact.Snapshot.LastResult);
    });

    private static void Redirects() => WithTemp(async directory =>
    {
        using (var same = Service(Path.Combine(directory, "same"), out var handler,
            (request, count) => count == 1 ? Redirect("/DoIt/moved.json") : Json(Manifest())))
        {
            await same.CheckAsync(manual: false);
            Equal(2, handler.Count);
            Equal<UpdateCheckResult?>(UpdateCheckResult.Ok, same.Snapshot.LastResult);
        }
        string[] rejected = ["https://example.invalid/DoIt/windows-release.json", "http://prestige-kim.github.io/DoIt/windows-release.json",
            "https://prestige-kim.github.io:8443/DoIt/windows-release.json", "https://user:pass" + "@" + "prestige-kim.github.io/DoIt/windows-release.json"];
        for (int i = 0; i < rejected.Length; i++)
        {
            using var service = Service(Path.Combine(directory, i.ToString()), out var counted, (_, _) => Redirect(rejected[i]));
            await service.CheckAsync(manual: false);
            Equal(1, counted.Count);
            Equal<UpdateCheckResult?>(UpdateCheckResult.Invalid, service.Snapshot.LastResult);
        }
        using var loop = Service(Path.Combine(directory, "loop"), out var looped, (_, _) => Redirect("/DoIt/windows-release.json"));
        await loop.CheckAsync(manual: false);
        Equal(5, looped.Count);
        Equal<UpdateCheckResult?>(UpdateCheckResult.Invalid, loop.Snapshot.LastResult);
    });

    private static void Failures() => WithTemp(async directory =>
    {
        var cases = new (string Name, Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> Reply, UpdateCheckResult Expected)[]
        {
            ("404", (_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.NotFound)), UpdateCheckResult.Unavailable),
            ("500", (_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.InternalServerError)), UpdateCheckResult.Unavailable),
            ("network", (_, _) => throw new HttpRequestException("synthetic"), UpdateCheckResult.Offline),
            ("timeout", async (_, token) => { await Task.Delay(Timeout.Infinite, token); throw new InvalidOperationException(); }, UpdateCheckResult.Offline),
            ("bad json", (_, _) => Task.FromResult(Json("{\"schemaVersion\":1")), UpdateCheckResult.Invalid),
        };
        foreach (var (name, reply, expected) in cases)
        {
            var handler = new FakeHandler((request, _, token) => reply(request, token));
            using var service = new UpdateService(Path.Combine(directory, name), Current, CurrentBuild, "x64", handler,
                new FakeClock(), TimeSpan.FromMilliseconds(100));
            Equal(true, await service.CheckAsync(manual: false));
            var snapshot = service.Snapshot;
            Equal<UpdateCheckResult?>(expected, snapshot.LastResult);
            Equal(false, snapshot.IsChecking);
            Equal<DateTimeOffset?>(null, snapshot.LastSuccessAt);
            Equal(false, UpdateDisplay.Status(snapshot).Contains("synthetic", StringComparison.Ordinal));
            // A failed attempt still counts for the 24-hour automatic interval.
            Equal(false, await service.CheckAsync(manual: false));
        }
    });

    private static void FailureKeepsRelease() => WithTemp(async directory =>
    {
        var clock = new FakeClock();
        using var service = Service(directory, out _, (_, count) =>
            count == 1 ? Json(Manifest()) : new HttpResponseMessage(HttpStatusCode.ServiceUnavailable), clock: clock);
        await service.CheckAsync(manual: false);
        clock.UtcNow = Now.AddMinutes(2);
        await service.CheckAsync(manual: true);
        var snapshot = service.Snapshot;
        Equal<UpdateCheckResult?>(UpdateCheckResult.Unavailable, snapshot.LastResult);
        Equal(Url("1.0.3", 4, "x64"), snapshot.DownloadUrl!.OriginalString);
        Equal(Now, snapshot.LastSuccessAt);
    });

    private static UpdateService Service(string directory, out FakeHandler handler,
        Func<HttpRequestMessage, int, HttpResponseMessage> reply, FakeClock? clock = null, string? architecture = "x64")
    {
        handler = new FakeHandler((request, count, _) => Task.FromResult(reply(request, count)));
        return new UpdateService(directory, Current, CurrentBuild, architecture, handler, clock ?? new FakeClock());
    }

    private static HttpResponseMessage Json(string body) => new(HttpStatusCode.OK)
    {
        Content = new StringContent(body, Encoding.UTF8, "application/json")
    };

    private static HttpResponseMessage Redirect(string target) => new(HttpStatusCode.Found)
    {
        Headers = { Location = new Uri(target, UriKind.RelativeOrAbsolute) }
    };

    private static void WithTemp(Func<string, Task> test)
    {
        string directory = Directory.CreateTempSubdirectory("doit-update-test-").FullName;
        try { test(directory).GetAwaiter().GetResult(); }
        finally { Directory.Delete(directory, recursive: true); }
    }

    private static void Equal<T>(T expected, T actual)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException($"Expected {expected}, got {actual}.");
        }
    }

    private sealed class FakeClock : TimeProvider
    {
        public DateTimeOffset UtcNow { get; set; } = Now;
        public override DateTimeOffset GetUtcNow() => UtcNow;
        public override TimeZoneInfo LocalTimeZone => TimeZoneInfo.Utc;
    }

    private sealed class FakeHandler : HttpMessageHandler
    {
        private readonly Func<HttpRequestMessage, int, CancellationToken, Task<HttpResponseMessage>> reply;
        private int count;

        public FakeHandler(Func<HttpRequestMessage, int, CancellationToken, Task<HttpResponseMessage>> reply) => this.reply = reply;
        public FakeHandler(Func<HttpRequestMessage, int, Task<HttpResponseMessage>> reply) => this.reply = (request, n, _) => reply(request, n);

        public int Count => Volatile.Read(ref count);

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            => reply(request, Interlocked.Increment(ref count), cancellationToken);
    }

    private sealed class NonSeekableStream(byte[] bytes) : MemoryStream(bytes)
    {
        public override bool CanSeek => false;
    }
}
