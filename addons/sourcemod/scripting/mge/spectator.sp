
// ===== SPECTATOR HUD MANAGEMENT =====

#define OBS_MODE_ROAMING 6

// Displays countdown messages to spectators watching a specific arena
void ShowCountdownToSpec(int arena_index, char[] text)
{
    if (!arena_index)
    {
        return;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if
        (
            IsValidClient(i)
            && GetClientTeam(i) == TEAM_SPEC
            && g_iPlayerArena[g_iPlayerSpecTarget[i]] == arena_index
        )
        {
            PrintCenterText(i, text);
        }
    }
}


// ===== TIMER FUNCTIONS =====

// Fixes spectator team assignment issues by cycling through teams
Action Timer_SpecFix(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (!IsValidClient(client))
        return Plugin_Continue;

    ChangeClientTeam(client, TEAM_RED);
    ChangeClientTeam(client, TEAM_SPEC);

    return Plugin_Continue;
}

// Updates spectator HUD for all arenas on a timer basis
Action Timer_SpecHudToAllArenas(Handle timer, int userid)
{
    for (int i = 1; i <= g_iArenaCount; i++)
    UpdateHudForArena(i);

    return Plugin_Continue;
}

// Changes dead player to spectator team after delay
Action Timer_ChangePlayerSpec(Handle timer, any player)
{
    if (IsValidClient(player) && !IsPlayerAlive(player))
    {
        ChangeClientTeam(player, TEAM_SPEC);
    }
    
    return Plugin_Continue;
}

// Updates spectator target and refreshes HUD when target changes
Action Timer_ChangeSpecTarget(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);

    if (!IsValidClient(client))
    {
        return Plugin_Stop;
    }
    
    // Only check if still in spectator team
    if (GetClientTeam(client) != TEAM_SPEC)
    {
        return Plugin_Stop;
    }
    
    // Check if player is actively fighting (not waiting in queue)
    // If they're in an active slot, don't update spec target
    int player_arena = g_iPlayerArena[client];
    int player_slot = g_iPlayerSlot[client];
    if (player_arena > 0 && player_slot > 0)
    {
        int max_active_slot = g_bFourPersonArena[player_arena] ? SLOT_FOUR : SLOT_TWO;
        if (player_slot <= max_active_slot)
        {
            // Player is in an active slot, shouldn't be spectating
            return Plugin_Stop;
        }
    }

    int target = GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");

    if (IsValidClient(target) && g_iPlayerArena[target] > 0 && IsPlayerAlive(target))
    {
        if (g_iPlayerSpecTarget[client] != target)
        {
            g_iPlayerSpecTarget[client] = target;
            UpdateHud(client);
        }
    }
    else
    {
        if (g_iPlayerSpecTarget[client] != 0)
        {
            HideHud(client);
            g_iPlayerSpecTarget[client] = 0;
        }
    }

    return Plugin_Stop;
}

// Shows periodic advertisements to spectators not in arenas
Action Timer_ShowAdv(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);

    if (IsValidClient(client) && g_iPlayerArena[client] == 0)
    {
        MC_PrintToChat(client, "%t", "Adv");
        CreateTimer(15.0, Timer_ShowAdv, userid);
    }

    return Plugin_Continue;
}


// ===== PLAYER COMMANDS =====

// Handles spectator command to detect and update spectator target
Action Command_Spec(int client, int args)
{  
    // Detecting spectator target
    if (!IsValidClient(client))
        return Plugin_Handled;

    CreateTimer(0.1, Timer_ChangeSpecTarget, GetClientUserId(client));
    return Plugin_Continue;
}

// Intercepts spec_next/spec_prev to cycle only through alive arena players,
// preventing spectators from landing on players not in any arena (empty HUD).
Action Command_SpecNavigation(int client, const char[] command, int args)
{
    if (!IsValidClient(client) || GetClientTeam(client) != TEAM_SPEC || g_iPlayerArena[client] > 0)
        return Plugin_Continue;

    bool isNext = StrEqual(command, "spec_next");
    bool isPrev = StrEqual(command, "spec_prev");
    if (!isNext && !isPrev)
        return Plugin_Continue;

    int observer_mode = GetEntProp(client, Prop_Send, "m_iObserverMode");
    if (observer_mode == OBS_MODE_ROAMING)
        return Plugin_Continue;

    int current_target = GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");

    int valid_targets[MAXPLAYERS + 1];
    int target_count = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidClient(i) && g_iPlayerArena[i] > 0 && IsPlayerAlive(i))
        {
            valid_targets[target_count++] = i;
        }
    }

    if (target_count == 0)
        return Plugin_Continue;

    int current_index = -1;
    for (int i = 0; i < target_count; i++)
    {
        if (valid_targets[i] == current_target)
        {
            current_index = i;
            break;
        }
    }

    int next_index;
    if (current_index == -1)
    {
        next_index = isNext ? 0 : (target_count - 1);
    }
    else if (isNext)
    {
        next_index = (current_index + 1) % target_count;
    }
    else
    {
        next_index = (current_index - 1 + target_count) % target_count;
    }

    int new_target = valid_targets[next_index];
    if (!IsValidClient(new_target) || !IsPlayerAlive(new_target) || g_iPlayerArena[new_target] <= 0)
        return Plugin_Continue;

    if (new_target != current_target)
        SetEntPropEnt(client, Prop_Send, "m_hObserverTarget", new_target);

    if (GetEntProp(client, Prop_Send, "m_iObserverMode") != observer_mode)
        SetEntProp(client, Prop_Send, "m_iObserverMode", observer_mode);

    g_iPlayerSpecTarget[client] = new_target;
    UpdateHud(client);

    return Plugin_Handled;
}
