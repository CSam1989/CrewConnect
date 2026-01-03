var builder = DistributedApplication.CreateBuilder(args);

builder.AddProject<Projects.CrewConnect_Web>("crewconnect-web");

builder.Build().Run();
