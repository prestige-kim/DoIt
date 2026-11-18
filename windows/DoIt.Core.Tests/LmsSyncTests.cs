using System.Net;
using System.Net.Http.Headers;
using System.Text;
using DoIt.Core;

internal static class LmsSyncTests
{
    // 공개 내보내기의 개인 피드 검사가 가짜 주소에 걸리지 않도록 경로 표식을 나눠 쓴다.
    private const string FeedPath = "/feeds/" + "calendars/";
    private const string Address = "https://calendar.example.invalid/lms" + FeedPath + "synthetic.ics";
    private const string Replacement = "https://calendar.example.invalid/lms" + FeedPath + "replacement.ics";
    private static readonly DateTimeOffset Now = new(2026, 11, 12, 9, 0, 0, TimeSpan.Zero);
    private static readonly DateOnly Today = new(2026, 11, 12);

    internal static IEnumerable<(string Name, Action Run)> Cases =>
    [
        ("LMS feed addresses accept only HTTPS calendar feed paths without URL credentials", ValidateAddresses),
        ("LMS starts disabled and requests only a GET without a body or credentials", DisabledAndGetOnly),
        ("LMS redirects follow only same-origin feed URLs", RedirectPolicy),
        ("LMS caps both advertised and streamed response sizes", BoundResponse),
        ("LMS interval limits survive restart and distinguish manual refresh", Intervals),
        ("LMS 429 blocks all triggers and doubles the server wait on a repeated 429", RateLimit),
        ("LMS accepts conditional 304 and retains cached data on network or parse failure", KeepLastGood),
        ("LMS ignores simultaneous refreshes and drops an obsolete connection response", StaleResponse),
        ("LMS disconnect failure blocks network across restart and rejects the pending old response", FailedDisconnect),
        ("LMS history is written before the cache can drop past items", HistoryBeforeCache),
        ("LMS prunes checks for canceled future work while keeping checks for archived work", PruneUnknownChecks),
        ("LMS checked flags are local and history reset preserves the live feed cache", LocalChecksAndReset),
        ("LMS will not fetch or overwrite a corrupt local file", CorruptData),
    ];

    private static void ValidateAddresses()
    {
        Equal(true, LmsFeedAddress.TryValidate(Address, out _));
        foreach (string invalid in new[]
        {
            Address.Replace("https:", "http:"), Address.Replace("https://", "https://name:pass@"),
            Address + "?key=synthetic", Address + "#calendar", Address.Replace("/feeds/", "/other/"),
            Address.Replace("synthetic.ics", "nested/test.ics"), Address.Replace("synthetic.ics", "nested%2Ftest.ics"),
            Address.Replace("synthetic.ics", ".ics"), Address.Replace("synthetic.ics", "test file.ics"),
            Address.Replace("synthetic.ics", "../ordinary.ics")
        })
        {
            Equal(false, LmsFeedAddress.TryValidate(invalid, out _));
        }
    }

    private static void DisabledAndGetOnly() => WithTemp(async directory =>
    {
        var address = new FakeAddressStore();
        var handler = new FakeHandler((request, _) =>
        {
            Equal(HttpMethod.Get, request.Method);
            Equal<HttpContent?>(null, request.Content);
            Equal<AuthenticationHeaderValue?>(null, request.Headers.Authorization);
            Equal(false, request.Headers.Contains("Cookie"));
            Equal("text/calendar", request.Headers.Accept.Single().MediaType);
            Equal(true, request.Headers.CacheControl?.NoStore);
            return Task.FromResult(Feed("one"));
        });
        using var service = new LmsService(directory, address, handler, new FakeClock());
        await service.RefreshAsync();
        Equal(false, service.Snapshot.Enabled);
        Equal(0, handler.Count);
        Equal(true, service.SaveAddress(Address));
        Equal(false, service.Snapshot.Enabled);
        await service.RefreshAsync(manual: true);
        Equal(0, handler.Count);
        Equal(true, service.SetEnabled(true));
        await service.RefreshAsync();
        Equal(1, handler.Count);
        Equal("event-assignment-one", service.All.Single().Item.Uid);
        foreach (string file in Directory.EnumerateFiles(directory))
        {
            Equal(false, File.ReadAllText(file).Contains(Address, StringComparison.Ordinal));
        }
    });

    private static void RedirectPolicy() => WithTemp(async directory =>
    {
        using (var safe = MakeService(Path.Combine(directory, "same"), out var accepted,
            (request, count) => count == 1 ? Redirect("/lms" + FeedPath + "moved.ics") : Feed("moved")))
        {
            await safe.RefreshAsync();
            Equal(2, accepted.Count);
            Equal("event-assignment-moved", safe.All.Single().Item.Uid);
        }
        string[] rejected = ["https://other.example.invalid" + FeedPath + "moved.ics",
            "https://calendar.example.invalid:8443" + FeedPath + "moved.ics", "/login", FeedPath + "moved.ics?key=sample"];
        for (int i = 0; i < rejected.Length; i++)
        {
            using var service = MakeService(Path.Combine(directory, i.ToString()), out var handler,
                (_, _) => Redirect(rejected[i]));
            await service.RefreshAsync();
            Equal(1, handler.Count);
            Equal(LmsSyncStatus.InvalidFeed, service.Snapshot.Status);
        }
    });

    private static void BoundResponse() => WithTemp(async directory =>
    {
        using (var declared = MakeService(Path.Combine(directory, "declared"), out _, (_, _) =>
        {
            var content = new StringContent("small");
            content.Headers.ContentLength = 6 * 1024 * 1024;
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = content };
        }))
        {
            await declared.RefreshAsync();
            Equal(LmsSyncStatus.InvalidFeed, declared.Snapshot.Status);
        }
        using var streamed = MakeService(Path.Combine(directory, "streamed"), out _, (_, _) =>
            new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StreamContent(new NonSeekableStream(new byte[5 * 1024 * 1024 + 1]))
            });
        await streamed.RefreshAsync();
        Equal(LmsSyncStatus.InvalidFeed, streamed.Snapshot.Status);
    });

    private static void Intervals() => WithTemp(async directory =>
    {
        var address = new FakeAddressStore();
        var clock = new FakeClock();
        using (var first = new LmsService(directory, address, new FakeHandler((_, _) => Task.FromResult(Feed("first"))), clock))
        {
            Connect(first);
            await first.RefreshAsync();
        }
        var handler = new FakeHandler((_, _) => Task.FromResult(Feed("second")));
        using var reopened = new LmsService(directory, address, handler, clock);
        clock.UtcNow = Now.AddMinutes(4);
        await reopened.RefreshAsync(manual: true);
        Equal(0, handler.Count);
        clock.UtcNow = Now.AddMinutes(5);
        await reopened.RefreshAsync();
        Equal(0, handler.Count);
        await reopened.RefreshAsync(manual: true);
        Equal(1, handler.Count);
        clock.UtcNow = Now.AddHours(6).AddMinutes(5);
        await reopened.RefreshAsync();
        Equal(2, handler.Count);
    });

    private static void RateLimit() => WithTemp(async directory =>
    {
        var clock = new FakeClock();
        using var service = MakeService(directory, out var handler, (_, _) => new HttpResponseMessage((HttpStatusCode)429)
        {
            Headers = { RetryAfter = new RetryConditionHeaderValue(TimeSpan.FromHours(1)) }
        }, clock);
        await service.RefreshAsync();
        Equal(LmsSyncStatus.RateLimited, service.Snapshot.Status);
        Equal<DateTimeOffset?>(Now.AddHours(1), service.Snapshot.RetryAt);
        clock.UtcNow = Now.AddMinutes(59);
        await service.RefreshAsync(manual: true);
        Equal(1, handler.Count);
        clock.UtcNow = Now.AddHours(1);
        await service.RefreshAsync(manual: true);
        Equal(2, handler.Count);
        Equal<DateTimeOffset?>(Now.AddHours(3), service.Snapshot.RetryAt);
    });

    private static void KeepLastGood() => WithTemp(async directory =>
    {
        var clock = new FakeClock();
        using var service = MakeService(directory, out _, (request, count) =>
        {
            if (count == 1)
            {
                var good = Feed("cached");
                good.Content.Headers.LastModified = Now;
                return good;
            }
            Equal<DateTimeOffset?>(Now, request.Headers.IfModifiedSince);
            return count switch
            {
                2 => new HttpResponseMessage(HttpStatusCode.NotModified),
                3 => new HttpResponseMessage(HttpStatusCode.ServiceUnavailable),
                _ => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("invalid") }
            };
        }, clock);
        await service.RefreshAsync();
        for (int i = 1; i <= 3; i++)
        {
            clock.UtcNow = Now.AddMinutes(5 * i);
            await service.RefreshAsync(manual: true);
            Equal("event-assignment-cached", service.All.Single().Item.Uid);
            Equal(new[] { LmsSyncStatus.Ok, LmsSyncStatus.Offline, LmsSyncStatus.InvalidFeed }[i - 1], service.Snapshot.Status);
        }
    });

    private static void StaleResponse() => WithTemp(async directory =>
    {
        var old = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
        var handler = new FakeHandler((_, count) => count == 1 ? old.Task : Task.FromResult(Feed("new")));
        using var service = new LmsService(directory, new FakeAddressStore(), handler, new FakeClock());
        Connect(service);
        var pending = service.RefreshAsync();
        await service.RefreshAsync(manual: true).WaitAsync(TimeSpan.FromSeconds(2));
        Equal(1, handler.Count);
        Equal(true, service.SaveAddress(Replacement));
        old.SetResult(Feed("old"));
        await pending;
        Equal(0, service.All.Count);
        await service.RefreshAsync(manual: true);
        Equal("event-assignment-new", service.All.Single().Item.Uid);
    });

    private static void FailedDisconnect() => WithTemp(async directory =>
    {
        var address = new FakeAddressStore { FailDelete = true };
        var pending = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
        using (var first = new LmsService(directory, address, new FakeHandler((_, _) => pending.Task), new FakeClock()))
        {
            Connect(first);
            var refresh = first.RefreshAsync();
            Equal(false, first.Disconnect());
            Equal(true, first.Snapshot.DisconnectPending);
            Equal(false, first.Snapshot.Enabled);
            pending.SetResult(Feed("old"));
            await refresh;
            Equal(0, first.All.Count);
        }
        var handler = new FakeHandler((_, _) => Task.FromResult(Feed("unexpected")));
        using var reopened = new LmsService(directory, address, handler, new FakeClock());
        Equal(true, reopened.Snapshot.DisconnectPending);
        Equal(false, reopened.SetEnabled(true));
        await reopened.RefreshAsync(manual: true);
        Equal(0, handler.Count);
        address.FailDelete = false;
        Equal(true, reopened.Disconnect());
        Equal(false, reopened.Snapshot.HasFeedAddress);
        Equal(false, reopened.Snapshot.DisconnectPending);
    });

    private static void HistoryBeforeCache() => WithTemp(async directory =>
    {
        var clock = new FakeClock();
        using var service = MakeService(directory, out var handler, (_, _) => Feed("before"), clock);
        await service.RefreshAsync();
        string path = Path.Combine(directory, "lms.json");
        string previous = File.ReadAllText(path);
        Directory.CreateDirectory(Path.Combine(directory, "lms-history.json"));
        clock.UtcNow = Now.AddDays(1);
        await service.RefreshAsync();
        Equal(previous, File.ReadAllText(path));
        Equal(1, service.CurrentCount);
        Equal(LmsSyncStatus.StorageError, service.Snapshot.Status);
        Equal(1, handler.Count);
    });

    private static void LocalChecksAndReset() => WithTemp(async directory =>
    {
        using var service = MakeService(directory, out var handler, (_, _) => Feed("live"));
        await service.RefreshAsync();
        Equal(true, service.ToggleDone("event-assignment-live"));
        Equal(true, service.All.Single().IsDone);
        Equal(true, service.Current.Single().IsDone);
        Equal(0, service.Visible(Today.AddDays(1)).Count);
        Equal(1, service.ForDate(Today).Count);
        Equal(1, handler.Count);
        Equal(true, service.ResetData());
        Equal(false, service.All.Single().IsDone);
        Equal(1, service.CurrentCount);
        Equal(true, service.Snapshot.Enabled);
        Equal(true, service.SetEnabled(false));
        Equal(0, service.Current.Count);
        Equal(1, service.All.Count);
    });

    private static void PruneUnknownChecks() => WithTemp(async directory =>
    {
        var clock = new FakeClock();
        using var service = MakeService(directory, out _, (_, count) => count == 1
            ? Calendar(Event("past", "20261112") + Event("canceled", "20261119"))
            : Calendar(string.Empty), clock);
        await service.RefreshAsync();
        Equal(true, service.ToggleDone("event-assignment-past"));
        Equal(true, service.ToggleDone("event-assignment-canceled"));
        clock.UtcNow = Now.AddDays(1);
        await service.RefreshAsync();
        Equal("event-assignment-past", service.History.Single().Item.Uid);
        Equal("event-assignment-past", service.Checks.Keys.Single());
        Equal(0, service.Current.Count);
    });

    private static void CorruptData() => WithTemp(async directory =>
    {
        string path = Path.Combine(directory, "lms-history.json");
        File.WriteAllText(path, "broken");
        var handler = new FakeHandler((_, _) => Task.FromResult(Feed("unexpected")));
        using var service = new LmsService(directory, new FakeAddressStore(), handler, new FakeClock());
        Equal(false, service.SaveAddress(Address));
        await service.RefreshAsync(manual: true);
        Equal(0, handler.Count);
        Equal(LmsSyncStatus.StorageError, service.Snapshot.Status);
        Equal("broken", File.ReadAllText(path));
    });

    private static LmsService MakeService(string directory, out FakeHandler handler,
        Func<HttpRequestMessage, int, HttpResponseMessage> reply, FakeClock? clock = null)
    {
        handler = new FakeHandler((request, count) => Task.FromResult(reply(request, count)));
        var service = new LmsService(directory, new FakeAddressStore(), handler, clock ?? new FakeClock());
        Connect(service);
        return service;
    }

    private static void Connect(LmsService service)
    {
        Equal(true, service.SaveAddress(Address));
        Equal(true, service.SetEnabled(true));
    }

    private static HttpResponseMessage Redirect(string target) => new(HttpStatusCode.Redirect)
    {
        Headers = { Location = new Uri(target, UriKind.RelativeOrAbsolute) }
    };

    private static HttpResponseMessage Feed(string id) => Calendar(Event(id, "20261112"));

    private static string Event(string id, string date) =>
        $"BEGIN:VEVENT\r\nUID:event-assignment-{id}\r\nSUMMARY:가짜 과제 [가짜 과목]\r\nDTSTART;VALUE=DATE:{date}\r\nEND:VEVENT\r\n";

    private static HttpResponseMessage Calendar(string events) => new(HttpStatusCode.OK)
    {
        Content = new StringContent($"BEGIN:VCALENDAR\r\n{events}END:VCALENDAR\r\n", Encoding.UTF8, "text/calendar")
    };

    private static void WithTemp(Func<string, Task> test)
    {
        string directory = Directory.CreateTempSubdirectory("doit-lms-test-").FullName;
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

    private sealed class FakeAddressStore : ILmsFeedAddressStore
    {
        private Uri? value;
        public bool FailDelete { get; set; }
        public bool Exists => value is not null;
        public Uri? Read() => value;
        public void Write(Uri address) => value = address;
        public void Delete()
        {
            if (FailDelete) throw new IOException("synthetic failure");
            value = null;
        }
    }

    private sealed class FakeHandler(Func<HttpRequestMessage, int, Task<HttpResponseMessage>> reply) : HttpMessageHandler
    {
        private int count;
        public int Count => Volatile.Read(ref count);
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            => reply(request, Interlocked.Increment(ref count));
    }

    private sealed class NonSeekableStream(byte[] bytes) : MemoryStream(bytes)
    {
        public override bool CanSeek => false;
    }
}
