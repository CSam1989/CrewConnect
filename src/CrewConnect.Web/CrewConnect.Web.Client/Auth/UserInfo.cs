namespace CrewConnect.Web.Client.Auth;

/// <summary>
/// User information received from the server for authentication state.
/// </summary>
public sealed class UserInfo
{
    public required string UserId { get; init; }
    public required string Email { get; init; }
    public string? Name { get; init; }
}
