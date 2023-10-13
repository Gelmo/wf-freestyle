/*
Copyright (C) 2009-2010 Chasseur de bots

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
*/

Vec3 playerMins( -16.0, -16.0, -24.0 );
Vec3 playerMaxs( 16.0, 16.0, 40.0 );

Cvar race_forceFiles( "race_forcefiles", "", CVAR_ARCHIVE );

enum Verbosity {
    Verbosity_Silent,
    Verbosity_Verbose,
};

const float HITBOX_EPSILON = 0.01f;

// msc: practicemode message
uint noclipModeMsg, recallModeMsg, defaultMsg;

EntityFinder entityFinder;

const uint SLICK_ABOVE = 32;
const uint SLICK_BELOW = 2048;

///*****************************************************************
/// LOCAL FUNCTIONS
///*****************************************************************

Client@[] RACE_GetSpectators( Client@ client )
{
    Client@[] speclist;
    for ( int i = 0; i < maxClients; i++ )
    {
        Client@ specClient = @G_GetClient(i);

        if ( specClient.chaseActive && specClient.chaseTarget == client.getEnt().entNum )
            speclist.push_back( @specClient );
    }
    return speclist;
}

// a player has just died. The script is warned about it so it can account scores
void RACE_playerKilled( Entity@ target, Entity@ attacker, Entity@ inflicter )
{
    if ( @target == null || @target.client == null )
        return;
}

void RACE_SetUpMatch()
{
    int i, j;
    Entity@ ent;
    Team@ team;

    gametype.shootingDisabled = false;
    gametype.readyAnnouncementEnabled = false;
    gametype.scoreAnnouncementEnabled = false;
    gametype.countdownEnabled = true;

    gametype.pickableItemsMask = gametype.spawnableItemsMask;
    gametype.dropableItemsMask = gametype.spawnableItemsMask;

    // clear player stats and scores, team scores

    for ( i = TEAM_PLAYERS; i < GS_MAX_TEAMS; i++ )
    {
        @team = G_GetTeam( i );
        team.stats.clear();
    }

    G_RemoveDeadBodies();
}

uint[] intro_timestamp( maxClients );
void RACE_IntroDelay(Client@ client, int delay)
{
    if ( delay > 0 )
    {
        intro_timestamp[client.playerNum] = levelTime + delay;
        return;
    }
    intro_timestamp[client.playerNum] = 0;
}

void RACE_ShowIntro(Client@ client)
{
    if ( client.getUserInfoKey("freestyle_seenintro").toInt() == 0 )
    {
        client.execGameCommand("meop freestyle_main");
    }
}

void RACE_ForceFiles()
{
    // msc: force pk3 download
    String token = race_forceFiles.string.getToken( 0 );
    for ( int i = 1; token != ""; i++ )
    {
        G_SoundIndex( token, true );
        token = race_forceFiles.string.getToken( i );
    }
}

///*****************************************************************
/// MODULE SCRIPT CALLS
///*****************************************************************

bool GT_Command( Client@ client, const String &cmdString, const String &argsString, int argc )
{
    return RACE_HandleCommand( client, cmdString, argsString, argc );
}

// When this function is called the weights of items have been reset to their default values,
// this means, the weights *are set*, and what this function does is scaling them depending
// on the current bot status.
// Player, and non-item entities don't have any weight set. So they will be ignored by the bot
// unless a weight is assigned here.
bool GT_UpdateBotStatus( Entity@ self )
{
    return false; // let the default code handle it itself
}

// select a spawning point for a player
Entity@ GT_SelectSpawnPoint( Entity@ self )
{
    return GENERIC_SelectBestRandomSpawnPoint( self, "info_player_deathmatch" );
}

String@ GT_ScoreboardMessage( uint maxlen )
{
    String scoreboardMessage = "";
    String entry;
    Team@ team;
    Player@ player;
    int i;

    @team = G_GetTeam( TEAM_PLAYERS );

    entry = "&t " + int( TEAM_PLAYERS ) + " 0 " + team.ping + " ";
    if ( scoreboardMessage.length() + entry.length() < maxlen )
        scoreboardMessage += entry;

    // add players without time
    for ( i = 0; @team.ent( i ) != null; i++ )
    {
        @player = RACE_GetPlayer( team.ent( i ).client );
        entry = player.scoreboardEntry();
        if ( scoreboardMessage.length() + entry.length() < maxlen )
            scoreboardMessage += entry;
    }

    return scoreboardMessage;
}

// Some game actions trigger score events. These are events not related to killing
// oponents, like capturing a flag
// Warning: client can be null
void GT_ScoreEvent( Client@ client, const String &score_event, const String &args )
{
    if ( score_event == "dmg" )
    {
    }
    else if ( score_event == "kill" )
    {
        Entity@ attacker = null;

        if ( @client != null )
            @attacker = client.getEnt();

        int arg1 = args.getToken( 0 ).toInt();
        int arg2 = args.getToken( 1 ).toInt();

        // target, attacker, inflictor
        RACE_playerKilled( G_GetEntity( arg1 ), attacker, G_GetEntity( arg2 ) );
    }
    else if ( score_event == "award" )
    {
    }
    else if ( score_event == "enterGame" )
    {
        if ( @client != null )
        {
            RACE_GetPlayer( client ).clear();
        }

        RACE_IntroDelay(client, 2000);
    }
}

// a player is being respawned. This can happen from several ways, as dying, changing team,
// being moved to ghost state, be placed in respawn queue, being spawned from spawn queue, etc
void GT_PlayerRespawn( Entity@ ent, int old_team, int new_team )
{
    if ( pending_endmatch )
    {
        if ( ent.client.team != TEAM_SPECTATOR )
        {
            ent.client.team = TEAM_SPECTATOR;
            ent.client.respawn(false);
        }
        return;
    }

    RACE_GetPlayer( ent.client ).spawn( old_team, new_team );
}

// Thinking function. Called each frame
void GT_ThinkRules()
{
    if ( match.scoreLimitHit() || match.timeLimitHit() || match.suddenDeathFinished() )
        match.launchState( match.getState() + 1 );

    if ( match.getState() >= MATCH_STATE_POSTMATCH )
        return;

    GENERIC_Think();

    //Hook
    for ( int i = 0; i < maxClients; i++ )
    {
        Hookers[i].Update(); 
    }

    // set all clients race stats
    Client@ client;
    Player@ player;

    for ( int i = 0; i < maxClients; i++ )
    {
        @client = G_GetClient( i );
        if ( client.state() < CS_SPAWNED )
            continue;

        //delayed intro
        if ( intro_timestamp[i] < levelTime && intro_timestamp[i] != 0 )
        {
            RACE_IntroDelay(client, 0);
            RACE_ShowIntro(client);
        }

        // disable gunblade autoattack
        client.pmoveFeatures = client.pmoveFeatures & ~PMFEAT_GUNBLADEAUTOATTACK;

        // always clear all before setting
        client.setHUDStat( STAT_PROGRESS_SELF, 0 );
        //client.setHUDStat( STAT_PROGRESS_OTHER, 0 );
        client.setHUDStat( STAT_IMAGE_SELF, 0 );
        client.setHUDStat( STAT_IMAGE_OTHER, 0 );
        client.setHUDStat( STAT_PROGRESS_ALPHA, 0 );
        client.setHUDStat( STAT_PROGRESS_BETA, 0 );
        client.setHUDStat( STAT_IMAGE_ALPHA, 0 );
        client.setHUDStat( STAT_IMAGE_BETA, 0 );
        client.setHUDStat( STAT_MESSAGE_SELF, 0 );
        client.setHUDStat( STAT_MESSAGE_OTHER, 0 );
        client.setHUDStat( STAT_MESSAGE_ALPHA, 0 );
        client.setHUDStat( STAT_MESSAGE_BETA, 0 );

        RACE_GetPlayer( client ).think();
    }
}

bool pending_endmatch = false;

// The game has detected the end of the match state, but it
// doesn't advance it before calling this function.
// This function must give permission to move into the next
// state by returning true.
bool GT_MatchStateFinished( int incomingMatchState )
{
    if ( incomingMatchState == MATCH_STATE_WAITEXIT )
    {
        G_CmdExecute("set g_inactivity_maxtime 90\n");
        G_CmdExecute("set g_disable_vote_remove 1\n");

        if ( randmap_passed != "" )
            G_CmdExecute( "map " + randmap_passed );
    }

    if ( incomingMatchState == MATCH_STATE_POSTMATCH )
    {
        // msc: check for overtime
        G_CmdExecute("set g_inactivity_maxtime 5\n");
        G_CmdExecute("set g_disable_vote_remove 0\n");
    }

    return true;
}

// the match state has just moved into a new state. Here is the
// place to set up the new state rules
void GT_MatchStateStarted()
{
    // hettoo : skip warmup and countdown
    if ( match.getState() < MATCH_STATE_PLAYTIME )
    {
        match.launchState( MATCH_STATE_PLAYTIME );
        return;
    }

    switch ( match.getState() )
    {
        case MATCH_STATE_PLAYTIME:
            RACE_SetUpMatch();
            break;

        case MATCH_STATE_POSTMATCH:
            gametype.pickableItemsMask = 0;
            gametype.dropableItemsMask = 0;
            GENERIC_SetUpEndMatch();
            break;

        default:
            break;
    }
}

// the gametype is shutting down cause of a match restart or map change
void GT_Shutdown()
{
}

// Temporary fix for hang from msc - https://github.com/DenMSC/racemod_2.1/commit/e073bed71de7f78b2a3d7dfeb8e1472e1d91442c
void target_relay_fix_use( Entity @self, Entity @other, Entity @activator )
{
    if ( ( self.spawnFlags & 4 ) != 0 )
    {
        array<Entity @> targets = self.findTargets();
        Entity @target = targets[ rand() % targets.length ];
        if( @target != null )
            __G_CallUse( target, self, activator );
        return;
    }
    self.useTargets( activator );
}

// The map entities have just been spawned. The level is initialized for
// playing, but nothing has yet started.
void GT_SpawnGametype()
{
    Cvar cm_mapHeader("cm_mapHeader", "", 0);

    //TODO: fix in source, /kill should reset touch timeouts.
    for ( int i = 0; i < numEntities; i++ )
    {
        Entity@ ent = G_GetEntity(i);

        // Temporary fix for hang from msc - https://github.com/DenMSC/racemod_2.1/commit/e073bed71de7f78b2a3d7dfeb8e1472e1d91442c
        if ( ent.classname == "target_relay" )
        {
            ent.freeEntity();
            Entity @new = G_SpawnEntity( "target_relay_fix" );
            @new.use = target_relay_fix_use;
        }

        if ( ent.classname == "target_teleporter" )
        {
            if ( cm_mapHeader.string != "FBSP" && ( ent.spawnFlags & 1 ) != 0 )
                ent.spawnFlags = ent.spawnFlags & ~1;
        }

        Vec3 centre = Centre( ent );
        if ( entityFinder.slicks.length() < 1 )
        {
            Trace slick;
            Vec3 slick_above = ent.origin;
            slick_above.z += SLICK_ABOVE;
            Vec3 slick_below = ent.origin;
            slick_below.z -= SLICK_BELOW;
            if ( slick.doTrace( slick_above, playerMins, playerMaxs, slick_below, ent.entNum, MASK_DEADSOLID ) && ( slick.surfFlags & SURF_SLICK ) > 0 )
            {
                entityFinder.add( "slick", null, slick.endPos );
            }
            else
            {
                slick_above = centre;
                slick_above.z += SLICK_ABOVE;
                slick_below = centre;
                slick_below.z -= SLICK_BELOW;
                if ( slick.doTrace( slick_above, playerMins, playerMaxs, slick_below, ent.entNum, MASK_DEADSOLID ) && ( slick.surfFlags & SURF_SLICK ) > 0 )
                    entityFinder.add( "slick", null, slick.endPos );
            }
        }
        if ( ent.classname == "target_starttimer" )
            entityFinder.addTriggering( "start", ent, false, true, null );
        else if ( ent.classname == "target_stoptimer" )
            entityFinder.addTriggering( "finish", ent, false, false, null );
        else if ( ent.classname == "info_player_deathmatch" || ent.classname == "info_player_start" )
        {
            Vec3 start = ent.origin;
            Vec3 end = ent.origin;
            Vec3 mins = playerMins;
            Vec3 maxs = playerMaxs;
            mins.x += HITBOX_EPSILON;
            mins.y += HITBOX_EPSILON;
            maxs.x -= HITBOX_EPSILON;
            maxs.y -= HITBOX_EPSILON;
            Trace tr;
            if ( tr.doTrace( start, mins, maxs, end, ent.entNum, MASK_DEADSOLID ) )
            {
                mins.z = 0;
                maxs.z = 0;
                start.z += playerMaxs.z;
                end.z += playerMins.z;
                if ( tr.doTrace( start, mins, maxs, end, ent.entNum, MASK_DEADSOLID ) && !tr.startSolid )
                {
                    Vec3 origin = tr.get_endPos();
                    origin.z -= playerMins.z;
                    ent.set_origin( origin );
                }
            }
        }
        else if ( ent.classname == "weapon_rocketlauncher" )
            entityFinder.addTriggering( "rl", ent, true, false, null );
        else if ( ent.classname == "weapon_grenadelauncher" )
            entityFinder.addTriggering( "gl", ent, true, false, null );
        else if ( ent.classname == "weapon_plasmagun" )
            entityFinder.addTriggering( "pg", ent, true, false, null );
        else if ( ent.classname == "trigger_push" || ent.classname == "trigger_push_velocity" )
            entityFinder.add( "push", ent, centre );
        else if ( ent.classname == "target_speed" )
            entityFinder.addTriggering( "push", ent, false, false, null );
        else if ( ent.classname == "func_door" || ent.classname == "func_door_rotating" )
            entityFinder.add( "door", ent, centre );
        else if ( ent.classname == "func_button" )
            entityFinder.add( "button", ent, centre );
        else if ( ent.classname == "misc_teleporter_dest" || ent.classname == "target_teleporter" )
            entityFinder.add( "tele", ent, centre );
    }
}

// Important: This function is called before any entity is spawned, and
// spawning entities from it is forbidden. If you want to make any entity
// spawning at initialization do it in GT_SpawnGametype, which is called
// right after the map entities spawning.

void GT_InitGametype()
{
    gametype.title = "Freestyle";
    gametype.version = "1.0";
    gametype.author = "Warsow Development Team";
    // Forked by Gelmo

    // if the gametype doesn't have a config file, create it
    if ( !G_FileExists( "configs/server/gametypes/" + gametype.name + ".cfg" ) )
    {
        String config;

        // the config file doesn't exist or it's empty, create it
        config = "// '" + gametype.title + "' gametype configuration file\n"
                 + "// This config will be executed each time the gametype is started\n"
                 + "\n\n// map rotation\n"
                 + "set g_maplist \"\" // list of maps in automatic rotation\n"
                 + "set g_maprotation \"0\"   // 0 = same map, 1 = in order, 2 = random\n"
                 + "\n// game settings\n"
                 + "set g_scorelimit \"0\"\n"
                 + "set g_timelimit \"0\"\n"
                 + "set g_warmup_timelimit \"0\"\n"
                 + "set g_match_extendedtime \"0\"\n"
                 + "set g_allow_falldamage \"0\"\n"
                 + "set g_allow_selfdamage \"0\"\n"
                 + "set g_allow_teamdamage \"0\"\n"
                 + "set g_allow_stun \"0\"\n"
                 + "set g_teams_maxplayers \"0\"\n"
                 + "set g_teams_allow_uneven \"0\"\n"
                 + "set g_countdown_time \"5\"\n"
                 + "set g_maxtimeouts \"0\" // -1 = unlimited\n"
                 + "set g_challengers_queue \"0\"\n"
                 + "\n// gametype settings\n"
                 + "set g_noclass_inventory \"gb mg rg gl rl pg lg eb cells shells grens rockets plasma lasers bolts bullets\"\n"
                 + "set g_class_strong_ammo \"99 99 99 99 99 99 99 99\" // GB MG RG GL RL PG LG EB\n"
                 + "set hook_enabled \"1\"\n"
                 + "set hook_limit \"1\"\n"
                 + "\necho " + gametype.name + ".cfg executed\n";

        G_WriteFile( "configs/server/gametypes/" + gametype.name + ".cfg", config );
        G_Print( "Created default config file for '" + gametype.name + "'\n" );
        G_CmdExecute( "exec configs/server/gametypes/" + gametype.name + ".cfg silent" );
    }

    gametype.spawnableItemsMask = ( IT_WEAPON | IT_AMMO | IT_ARMOR | IT_POWERUP | IT_HEALTH );
    if ( gametype.isInstagib )
        gametype.spawnableItemsMask &= ~uint( G_INSTAGIB_NEGATE_ITEMMASK );

    gametype.respawnableItemsMask = gametype.spawnableItemsMask;
    gametype.dropableItemsMask = 0;
    gametype.pickableItemsMask = ( gametype.spawnableItemsMask | gametype.dropableItemsMask );

    gametype.isTeamBased = false;
    gametype.isRace = true;
    gametype.hasChallengersQueue = false;
    gametype.maxPlayersPerTeam = 0;

    gametype.ammoRespawn = 1;
    gametype.armorRespawn = 1;
    gametype.weaponRespawn = 1;
    gametype.healthRespawn = 1;
    gametype.powerupRespawn = 1;
    gametype.megahealthRespawn = 1;
    gametype.ultrahealthRespawn = 1;

    gametype.readyAnnouncementEnabled = false;
    gametype.scoreAnnouncementEnabled = false;
    gametype.countdownEnabled = false;
    gametype.mathAbortDisabled = true;
    gametype.shootingDisabled = false;
    gametype.infiniteAmmo = true;
    gametype.canForceModels = true;
    gametype.canShowMinimap = false;
    gametype.teamOnlyMinimap = true;

    gametype.spawnpointRadius = 0;

    if ( gametype.isInstagib )
        gametype.spawnpointRadius *= 2;

    gametype.inverseScore = true;

    // set spawnsystem type
    for ( int team = TEAM_PLAYERS; team < GS_MAX_TEAMS; team++ )
        gametype.setTeamSpawnsystem( team, SPAWNSYSTEM_INSTANT, 0, 0, false );

    // define the scoreboard layout
    G_ConfigString( CS_SCB_PLAYERTAB_LAYOUT, "%n 112 %s 52 %l 40" );
    G_ConfigString( CS_SCB_PLAYERTAB_TITLES, "Name Clan Ping" );

    RACE_RegisterCommands();

    // add votes
    G_RegisterCallvote( "randmap", "<* | pattern>", "string", "Changes to a random map" );
    G_RegisterCallvote( "hook_enabled", "<1 or 0>", "bool", "Enables or disables grappling hook usage" );
    G_RegisterCallvote( "hook_limit", "<1 or 0>", "bool", "Enables or disables grappling hook speed limit" );

    // msc: practicemode message
    noclipModeMsg = G_RegisterHelpMessage(S_COLOR_CYAN + "Noclip");
    recallModeMsg = G_RegisterHelpMessage(S_COLOR_CYAN + "Recall Mode");
    defaultMsg = G_RegisterHelpMessage(" ");

    for ( int i = 0; i < maxClients; i++ )
    {
        @Hookers[i].client = @G_GetClient(i);
        @Hookers[i].player = @G_GetClient(i).getEnt();
    }

    RACE_ForceFiles();

    G_Print( "Gametype '" + gametype.title + "' initialized\n" );
}
