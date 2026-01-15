using CrewConnect.Web.Client.Pages;
using CrewConnect.Web.Components;
using CrewConnect.Infrastructure;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authentication.Google;
using Microsoft.AspNetCore.Components.Authorization;
using CrewConnect.Web.Auth;

var builder = WebApplication.CreateBuilder(args);

builder.AddServiceDefaults();

// Add services to the container.
builder.Services.AddRazorComponents()
    .AddInteractiveWebAssemblyComponents();

// Configure Authentication
builder.Services.AddAuthentication(options =>
{
    options.DefaultScheme = CookieAuthenticationDefaults.AuthenticationScheme;
    options.DefaultChallengeScheme = GoogleDefaults.AuthenticationScheme;
})
.AddCookie()
.AddGoogle(options =>
{
    var clientId = builder.Configuration["Authentication:Google:ClientId"];
    if (string.IsNullOrWhiteSpace(clientId))
    {
        throw new System.InvalidOperationException("Google ClientId is not configured. Please set 'Authentication:Google:ClientId' in the application configuration.");
    }

    var clientSecret = builder.Configuration["Authentication:Google:ClientSecret"];
    if (string.IsNullOrWhiteSpace(clientSecret))
    {
        throw new System.InvalidOperationException("Google ClientSecret is not configured. Please set 'Authentication:Google:ClientSecret' in the application configuration.");
    }

    options.ClientId = clientId;
    options.ClientSecret = clientSecret;
});

builder.Services.AddAuthorization();
builder.Services.AddCascadingAuthenticationState();
builder.Services.AddScoped<AuthenticationStateProvider, PersistingAuthenticationStateProvider>();

// Configure Infrastructure services (Database)
builder.Services.ConfigureDatabase(builder.Configuration);

var app = builder.Build();

app.MapDefaultEndpoints();

// Configure the HTTP request pipeline.
if (app.Environment.IsDevelopment())
{
    app.UseWebAssemblyDebugging();
}
else
{
    app.UseExceptionHandler("/Error", createScopeForErrors: true);
    // The default HSTS value is 30 days. You may want to change this for production scenarios, see https://aka.ms/aspnetcore-hsts.
    app.UseHsts();
}
app.UseStatusCodePagesWithReExecute("/not-found", createScopeForStatusCodePages: true);
app.UseHttpsRedirection();

app.UseAuthentication();
app.UseAuthorization();

app.UseAntiforgery();

app.MapStaticAssets();
app.MapRazorComponents<App>()
    .AddInteractiveWebAssemblyRenderMode()
    .AddAdditionalAssemblies(typeof(CrewConnect.Web.Client._Imports).Assembly);

// Authentication endpoints
app.MapGet("/authentication/login", async (HttpContext context, string? returnUrl) =>
{
    // Validate returnUrl is a local path to prevent open redirect attacks
    var isLocalUrl = !string.IsNullOrWhiteSpace(returnUrl) 
        && returnUrl.StartsWith('/') 
        && !returnUrl.StartsWith("//") 
        && !returnUrl.StartsWith("/\\");
    
    returnUrl = isLocalUrl ? returnUrl : "/";

    await context.ChallengeAsync(GoogleDefaults.AuthenticationScheme, new Microsoft.AspNetCore.Authentication.AuthenticationProperties
    {
        RedirectUri = returnUrl
    });
});

app.MapPost("/authentication/logout", async (HttpContext context) =>
{
    await context.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
    return Results.Redirect("/");
})
.RequireAuthorization();

app.Run();
