// VulnerableApp — intentionally insecure for SAST demonstration
// DO NOT USE IN PRODUCTION
using Microsoft.Data.Sqlite;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

// VULNERABILITY 1: Hardcoded credentials (S6290 / CWE-798)
const string DbPassword = "admin123!";
const string AdminApiKey = "sk-prod-a1b2c3d4e5f6g7h8i9j0";

// VULNERABILITY 2: SQL Injection (S2077 / CWE-89)
app.MapGet("/users/{username}", async (string username) =>
{
    using var conn = new SqliteConnection("Data Source=app.db");
    await conn.OpenAsync();

    // UNSAFE: user input concatenated directly into SQL
    var sql = $"SELECT * FROM users WHERE username = '{username}'";
    using var cmd = new SqliteCommand(sql, conn);
    using var reader = await cmd.ExecuteReaderAsync();
    var results = new List<string>();
    while (await reader.ReadAsync())
        results.Add(reader.GetString(0));
    return results;
});

// VULNERABILITY 3: Command Injection (S2076 / CWE-78)
app.MapGet("/ping/{host}", (string host) =>
{
    // UNSAFE: shell command with user input
    var process = System.Diagnostics.Process.Start("bash", $"-c 'ping -c 1 {host}'");
    process?.WaitForExit();
    return "Ping executed";
});

// VULNERABILITY 4: Insecure Random (S2245 / CWE-338)
app.MapGet("/token", () =>
{
    var rng = new Random(); // UNSAFE: not cryptographically secure
    var token = rng.Next(100000, 999999).ToString();
    return token;
});

// VULNERABILITY 5: Exposed exception details (S4507 / CWE-209)
app.MapGet("/data/{id}", (int id) =>
{
    try
    {
        if (id < 0) throw new ArgumentException("Invalid ID");
        return Results.Ok($"Data for {id}");
    }
    catch (Exception ex)
    {
        // UNSAFE: exposes stack trace to client
        return Results.Problem(ex.ToString());
    }
});

app.Logger.LogInformation("VulnerableApp starting — this is for SAST demo only");
app.Run();
