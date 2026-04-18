// ===== ON-DEMAND SPAWN CONFIG DOWNLOAD =====
//
// When a map's spawn config is not shipped locally, fetch it from a
// configurable upstream URL via the SteamWorks HTTP API. If SteamWorks is
// not loaded or the download fails, scan the spawn directory for a config
// whose filename prefix-matches the current map name with common version
// suffixes stripped (e.g. "_b5", "_rc1", "_final", trailing digits).
//
// SteamWorks is a soft dependency — natives are auto-MarkNativeAsOptional'd
// by SteamWorks.inc, so the plugin still loads if the extension is absent.

#define SPAWN_CONFIGS_DIR "configs/mge"
#define DEFAULT_SPAWN_CONFIGS_URL "https://raw.githubusercontent.com/mgetf/MGEMod/master/addons/sourcemod/configs/mge/%s.cfg"

// Strips common map-version suffixes so we can prefix-match against a
// shipped config for an earlier/later revision of the same map.
#define NORMALIZE_MAP_PATTERN "(_(a|b|beta|v|rc|f|final|fix|u|r|comptf|ugc)[0-9]*[a-z]?|_[0-9]+[a-z]?|_final|_fix)+$"

Convar gcvar_spawnConfigsUrl;
Convar gcvar_enableFallbackConfig;

bool g_bCanDownload;
bool g_bEnableFallbackConfig;
Regex g_hNormalizeMapRegex;
char g_sSpawnConfigsUrl[256];


// Called once from OnPluginStart. Registers cvars, compiles the
// suffix-stripping regex, and checks for the SteamWorks extension.
void InitSpawnDownload()
{
    g_bCanDownload = GetExtensionFileStatus("SteamWorks.ext") == 1;

    gcvar_spawnConfigsUrl = new Convar(
        "mgemod_spawn_configs_url",
        DEFAULT_SPAWN_CONFIGS_URL,
        "URL template for downloading per-map spawn configs when the map has no local config. %s is replaced with the map name. Requires the SteamWorks extension."
    );
    gcvar_enableFallbackConfig = new Convar(
        "mgemod_enable_fallback_config",
        "1",
        "Try loading a similarly-named map's config when the current map has no local or downloaded config.",
        FCVAR_NONE, true, 0.0, true, 1.0
    );

    gcvar_spawnConfigsUrl.GetString(g_sSpawnConfigsUrl, sizeof(g_sSpawnConfigsUrl));
    g_bEnableFallbackConfig = gcvar_enableFallbackConfig.BoolValue;

    gcvar_spawnConfigsUrl.AddChangeHook(OnSpawnConfigsUrlChanged);
    gcvar_enableFallbackConfig.AddChangeHook(OnEnableFallbackConfigChanged);

    g_hNormalizeMapRegex = new Regex(NORMALIZE_MAP_PATTERN, 0);
}

void OnSpawnConfigsUrlChanged(ConVar cv, const char[] oldVal, const char[] newVal)
{
    strcopy(g_sSpawnConfigsUrl, sizeof(g_sSpawnConfigsUrl), newVal);
}

void OnEnableFallbackConfigChanged(ConVar cv, const char[] oldVal, const char[] newVal)
{
    g_bEnableFallbackConfig = StringToInt(newVal) != 0;
}


// Primary entry point, called from OnMapStart in place of the old inline load.
// Populates g_sMapName and then either finishes spawn loading synchronously
// (local file hit) or kicks off an async HTTP request whose callback will
// eventually call OnSpawnsLoaded() or SetFailState.
void TryLoadOrDownloadSpawns()
{
    ResolveCurrentMapName();

    char txtfile[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, txtfile, sizeof(txtfile), "%s/%s.cfg", SPAWN_CONFIGS_DIR, g_sMapName);

    if (FileExists(txtfile))
    {
        LoadOrFail(txtfile);
        RefreshSpawnConfig(txtfile);
        return;
    }

    if (g_bCanDownload)
    {
        LogMessage("No local spawn config at %s. Attempting download for map %s...", txtfile, g_sMapName);
        DownloadSpawnConfig(txtfile);
        return;
    }

    LogMessage("No local spawn config at %s. SteamWorks extension not loaded, skipping download.", txtfile);
    TryFallbackOrFail();
}


void RefreshSpawnConfig(const char[] localPath)
{
    if (!g_bCanDownload)
        return;

    char url[512];
    Format(url, sizeof(url), g_sSpawnConfigsUrl, g_sMapName);

    Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, url);
    if (request == null)
        return;

    DataPack pack = new DataPack();
    pack.WriteString(g_sMapName);
    pack.WriteString(localPath);

    SteamWorks_SetHTTPRequestContextValue(request, view_as<int>(pack));
    SteamWorks_SetHTTPCallbacks(request, OnSpawnConfigRefreshComplete);
    SteamWorks_SendHTTPRequest(request);
}


public void OnSpawnConfigRefreshComplete(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    char mapName[128];
    char localPath[PLATFORM_MAX_PATH];
    pack.ReadString(mapName, sizeof(mapName));
    pack.ReadString(localPath, sizeof(localPath));
    delete pack;

    if (bRequestSuccessful && eStatusCode == k_EHTTPStatusCode200OK)
    {
        if (SteamWorks_WriteHTTPResponseBodyToFile(hRequest, localPath))
        {
            LogMessage("Refreshed spawn config for %s (applies on next load)", mapName);
        }
    }

    CloseHandle(hRequest);
}


// Load `txtfile` via LoadSpawnPointsFromFile and either continue map init
// via OnSpawnsLoaded(), or fail the plugin. Shared by the sync (local file)
// and async (downloaded or fallback) paths.
void LoadOrFail(const char[] txtfile)
{
    if (LoadSpawnPointsFromFile(txtfile))
    {
        OnSpawnsLoaded();
    }
    else
    {
        SetFailState("Map not supported. MGEMod disabled.");
    }
}


// Search SPAWN_CONFIGS_DIR for a config whose filename prefix-matches the
// current map name with common version suffixes stripped. Loads it if
// found, otherwise fails the plugin.
void TryFallbackOrFail()
{
    char fallbackPath[PLATFORM_MAX_PATH];
    if (GetFallbackConfigPath(g_sMapName, fallbackPath, sizeof(fallbackPath)))
    {
        LoadOrFail(fallbackPath);
        return;
    }
    SetFailState("Map not supported. MGEMod disabled.");
}


// Kick off the async download. The destination path is stashed on the
// request's context DataPack so the callback cannot race against a
// mid-flight map change (which would mutate g_sMapName under us).
void DownloadSpawnConfig(const char[] localPath)
{
    char url[512];
    Format(url, sizeof(url), g_sSpawnConfigsUrl, g_sMapName);

    LogMessage("GETing %s", url);

    Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, url);
    if (request == null)
    {
        LogError("SteamWorks_CreateHTTPRequest returned null for %s", url);
        TryFallbackOrFail();
        return;
    }

    DataPack pack = new DataPack();
    pack.WriteString(g_sMapName);
    pack.WriteString(localPath);

    SteamWorks_SetHTTPRequestContextValue(request, view_as<int>(pack));
    SteamWorks_SetHTTPCallbacks(request, OnSteamWorksHTTPComplete);
    SteamWorks_SendHTTPRequest(request);
}


public void OnSteamWorksHTTPComplete(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();

    char mapName[128];
    char localPath[PLATFORM_MAX_PATH];
    pack.ReadString(mapName, sizeof(mapName));
    pack.ReadString(localPath, sizeof(localPath));
    delete pack;

    if (bRequestSuccessful && eStatusCode == k_EHTTPStatusCode200OK)
    {
        if (SteamWorks_WriteHTTPResponseBodyToFile(hRequest, localPath))
        {
            LogMessage("Downloaded spawn config for %s to %s", mapName, localPath);
            LoadOrFail(localPath);
        }
        else
        {
            LogError("Failed to write downloaded spawn config to %s", localPath);
            TryFallbackOrFail();
        }
    }
    else
    {
        LogMessage(
            "Failed to download spawns for %s. StatusCode=%i bFailure=%i RequestSuccessful=%i",
            mapName, eStatusCode, bFailure, bRequestSuccessful
        );
        TryFallbackOrFail();
    }

    CloseHandle(hRequest);
}


// Strip common version suffixes from `map` and scan SPAWN_CONFIGS_DIR for
// a file whose name starts with the stripped form. Returns true and
// populates `path` if a near-match is found.
bool GetFallbackConfigPath(const char[] map, char[] path, int maxlength)
{
    if (!g_bEnableFallbackConfig)
    {
        return false;
    }
    LogMessage("No config for %s, searching for fallback...", map);

    char cleanMap[64];
    strcopy(cleanMap, sizeof(cleanMap), map);

    char match[64];
    int matchnum = g_hNormalizeMapRegex.Match(cleanMap);
    if (matchnum > 0 && g_hNormalizeMapRegex.GetSubString(0, match, sizeof(match), 0))
    {
        ReplaceString(cleanMap, sizeof(cleanMap), match, "", true);
        LogMessage("Normalised map name for fallback search: %s", cleanMap);
    }

    if (cleanMap[0] == '\0')
    {
        return false;
    }

    char dir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, dir, sizeof(dir), "%s", SPAWN_CONFIGS_DIR);
    DirectoryListing dh = OpenDirectory(dir);
    if (dh == null)
    {
        return false;
    }

    char file[128];
    char foundFile[128];
    bool foundMatch = false;
    while (dh.GetNext(file, sizeof(file)))
    {
        // Prefix match (case-insensitive), ignoring non-.cfg entries.
        // First hit wins.
        if (StrContains(file, cleanMap, false) == 0 && StrContains(file, ".cfg", false) != -1)
        {
            strcopy(foundFile, sizeof(foundFile), file);
            foundMatch = true;
            break;
        }
    }
    delete dh;

    if (foundMatch)
    {
        BuildPath(Path_SM, path, maxlength, "%s/%s", SPAWN_CONFIGS_DIR, foundFile);
        LogMessage("Loading fallback spawn config %s for map %s", foundFile, map);
        return true;
    }

    LogMessage("No fallback spawn config found for %s (normalised: %s).", map, cleanMap);
    return false;
}
