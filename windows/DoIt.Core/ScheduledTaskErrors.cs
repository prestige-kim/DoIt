namespace DoIt.Core;

public static class ScheduledTaskErrors
{
    // HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND). Task Scheduler returns it for a task that does not exist.
    // .NET maps this HRESULT to FileNotFoundException, not COMException, so match the HRESULT itself.
    public const int TaskNotFound = unchecked((int)0x80070002);

    public static bool IsTaskNotFound(Exception error) => error.HResult == TaskNotFound;
}
