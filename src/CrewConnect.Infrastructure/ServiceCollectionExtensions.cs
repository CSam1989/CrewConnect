using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace CrewConnect.Infrastructure;

public static class ServiceCollectionExtensions
{
    public static IServiceCollection ConfigureDatabase(this IServiceCollection services, IConfiguration configuration)
    {
        var connectionString = configuration.GetConnectionString("DefaultConnection");
        services.AddDbContext<CrewConnectDbContext>(options =>
            options.UseNpgsql(connectionString));
        return services;
    }
}
