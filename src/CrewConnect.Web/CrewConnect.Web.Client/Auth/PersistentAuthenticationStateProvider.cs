using Microsoft.AspNetCore.Components;
using Microsoft.AspNetCore.Components.Authorization;
using System.Security.Claims;

namespace CrewConnect.Web.Client.Auth;

/// <summary>
/// Client-side authentication state provider that reads persisted user info from PersistentComponentState.
/// </summary>
public sealed class PersistentAuthenticationStateProvider : AuthenticationStateProvider
{
    // Shared completed task representing an unauthenticated (empty) principal.
    // This is safe to reuse across instances and threads because the underlying
    // ClaimsPrincipal/ClaimsIdentity is used as an immutable, read-only sentinel.
    private static readonly Task<AuthenticationState> DefaultUnauthenticatedTask =
        Task.FromResult(new AuthenticationState(new ClaimsPrincipal(new ClaimsIdentity())));

    private readonly Task<AuthenticationState> _authenticationStateTask = DefaultUnauthenticatedTask;

    public PersistentAuthenticationStateProvider(PersistentComponentState state)
    {
        if (!state.TryTakeFromJson<UserInfo>(nameof(UserInfo), out var userInfo) || userInfo is null)
        {
            return;
        }

        var claims = new List<Claim>
        {
            new(ClaimTypes.NameIdentifier, userInfo.UserId),
            new(ClaimTypes.Email, userInfo.Email)
        };

        if (userInfo.Name is not null)
        {
            claims.Add(new Claim(ClaimTypes.Name, userInfo.Name));
        }

        _authenticationStateTask = Task.FromResult(
            new AuthenticationState(new ClaimsPrincipal(new ClaimsIdentity(claims, authenticationType: nameof(PersistentAuthenticationStateProvider)))));
    }

    public override Task<AuthenticationState> GetAuthenticationStateAsync() => _authenticationStateTask;
}
