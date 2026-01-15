namespace CrewConnect.Web.Auth;

/// <summary>
/// User information serialized for authentication state persistence between server and client.
/// </summary>
public sealed class UserInfo
{
    public required string UserId { get; init; }
    public required string Email { get; init; }
    public string? Name { get; init; }
}
