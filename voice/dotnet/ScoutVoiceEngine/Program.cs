using ScoutVoiceEngine;

internal static class Program
{
    [STAThread]
    public static async Task<int> Main(string[] args)
    {
        try
        {
            return await App.RunAsync(args);
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception);
            return 1;
        }
    }
}
