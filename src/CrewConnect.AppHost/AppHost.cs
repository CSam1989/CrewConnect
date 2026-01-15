var builder = DistributedApplication.CreateBuilder(args);

builder.AddProject<Projects.CrewConnect_Web>("crewconnect-web");

// Build and run the distributed application
builder.Build().Run();
