using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using DoIt.Core;

namespace DoIt.Windows;

internal sealed class ClosedReminderTask(string executable)
{
    internal const string Argument = "--due-reminder";
    private const int NotFound = unchecked((int)0x80070002);

    internal bool Replace(DayReminder? next)
    {
        using var identity = WindowsIdentity.GetCurrent();
        var sid = identity.User?.Value;
        if (sid is null) return false;
        string taskName = $"DoIt.DueReminder.{sid}";
        try
        {
            var type = Type.GetTypeFromProgID("Schedule.Service");
            if (type is null) return false;
            dynamic service = Activator.CreateInstance(type)!;
            service.Connect();
            dynamic root = service.GetFolder("\\");
            if (next is null)
            {
                try { root.DeleteTask(taskName, 0); }
                catch (COMException error) when (error.HResult == NotFound) { }
                return true;
            }

            dynamic task = service.NewTask(0);
            task.RegistrationInfo.Description = "DoIt 마감 알림";
            task.Principal.UserId = sid;
            task.Principal.LogonType = 3; // Interactive token, current user only.
            task.Principal.RunLevel = 0; // Least privilege.
            task.Settings.StartWhenAvailable = true;
            task.Settings.WakeToRun = false;
            task.Settings.DisallowStartIfOnBatteries = false;
            task.Settings.StopIfGoingOnBatteries = false;
            task.Settings.AllowDemandStart = false;
            task.Settings.ExecutionTimeLimit = "PT2M";
            task.Settings.DeleteExpiredTaskAfter = "PT1M";
            dynamic trigger = task.Triggers.Create(1); // Single time trigger.
            trigger.StartBoundary = Format(next.FireAt);
            trigger.EndBoundary = Format(next.FireAt.AddDays(1));
            dynamic action = task.Actions.Create(0); // Local installed executable, not a shell command.
            action.Path = executable;
            action.Arguments = Argument;
            action.WorkingDirectory = Path.GetDirectoryName(executable);
            root.RegisterTaskDefinition(taskName, task, 6, sid, null, 3, null); // Create or update, interactive token.
            return true;
        }
        catch (Exception error) when (error is COMException or UnauthorizedAccessException
            or System.Security.SecurityException or Microsoft.CSharp.RuntimeBinder.RuntimeBinderException)
        {
            return false;
        }
    }

    private static string Format(DateTimeOffset value) => value.ToString("yyyy-MM-dd'T'HH:mm:sszzz", CultureInfo.InvariantCulture);
}
