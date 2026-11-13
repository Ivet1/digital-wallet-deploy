FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

COPY *.csproj ./
RUN --mount=type=cache,target=/root/.nuget/packages \
    dotnet restore

COPY . ./
RUN --mount=type=cache,target=/root/.nuget/packages \
    dotnet publish DigitalWallet.Api.csproj -c Release -o /app/publish


FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app

RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
    libgssapi-krb5-2 \
    libc6 \
    libstdc++6 \
    zlib1g \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m appuser && chown -R appuser /app

COPY --from=build --chown=appuser:appuser /app/publish .

USER appuser

EXPOSE 8080
ENV ASPNETCORE_URLS=http://+:8080

ENTRYPOINT ["dotnet", "DigitalWallet.Api.dll"]