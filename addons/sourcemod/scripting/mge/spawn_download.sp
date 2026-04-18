// ===== ON-DEMAND SPAWN CONFIG DOWNLOAD =====
//
// When a map's spawn config is not shipped locally, fetch it from a
// configurable upstream URL via the SteamWorks HTTP API. If SteamWorks is
// not loaded or the download fails, the plugin fails the map load as
// before.
//
// SteamWorks is a soft dependency — natives are auto-MarkNativeAsOptional'd
// by SteamWorks.inc, so the plugin still loads if the extension is absent.

#define SPAWN_CONFIGS_DIR "configs/mge"
#define DEFAULT_SPAWN_CONFIGS_URL "https://raw.githubusercontent.com/mgetf/MGEMod/master/addons/sourcemod/configs/mge/%s.cfg"

Convar gcvar_spawnConfigsUrl;

bool g_bCanDownload;
char g_sSpawnConfigsUrl[256];


// Called once from OnPluginStart. Registers the URL cvar and checks for
// the SteamWorks extension.
void InitSpawnDownload()
{
    g_bCanDownload = GetExtensionFileStatus("SteamWorks.ext") == 1;

    gcvar_spawnConfigsUrl = new Convar(
        "mgemod_spawn_configs_url",
        DEFAULT_SPAWN_CONFIGS_URL,
        "URL template for downloading per-map spawn configs when the map has no local config. %s is replaced with the map name. Requires the SteamWorks extension."
    );

    gcvar_spawnConfigsUrl.GetString(g_sSpawnConfigsUrl, sizeof(g_sSpawnConfigsUrl));

    gcvar_spawnConfigsUrl.AddChangeHook(OnSpawnConfigsUrlChanged);
}

void OnSpawnConfigsUrlChanged(ConVar cv, const char[] oldVal, const char[] newVal)
{
    strcopy(g_sSpawnConfigsUrl, sizeof(g_sSpawnConfigsUrl), newVal);
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
        return;
    }

    if (g_bCanDownload)
    {
        LogMessage("No local spawn config at %s. Attempting download for map %s...", txtfile, g_sMapName);
        DownloadSpawnConfig(txtfile);
        return;
    }

    LogMessage("No local spawn config at %s. SteamWorks extension not loaded, skipping download.", txtfile);
    SetFailState("Map not supported. MGEMod disabled.");
}


// Load `txtfile` via LoadSpawnPointsFromFile and either continue map init
// via OnSpawnsLoaded(), or fail the plugin. Shared by the sync (local file)
// and async (downloaded) paths.
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
        SetFailState("Map not supported. MGEMod disabled.");
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
            SetFailState("Map not supported. MGEMod disabled.");
        }
    }
    else
    {
        LogMessage(
            "Failed to download spawns for %s. StatusCode=%i bFailure=%i RequestSuccessful=%i",
            mapName, eStatusCode, bFailure, bRequestSuccessful
        );
        SetFailState("Map not supported. MGEMod disabled.");
    }

    CloseHandle(hRequest);
}
