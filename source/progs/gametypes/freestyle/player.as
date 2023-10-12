const int MAX_POSITIONS = 400;
const int POSITION_INTERVAL = 500;

const int RECALL_ACTION_TIME = 200;
const int RECALL_ACTION_JUMP = 5;
const int RECALL_HOLD = 20;

const float POINT_DISTANCE = 65536.0f;
const float POINT_PULL = 0.004f;
const float PULL_MARGIN = 16.0f;

const uint BIG_LIST = 15;

Player[] players( maxClients );

class Player
{
    Client@ client;

    int currentSector;

    uint forceRespawn;

    int positionCycle;

    PositionStore freestylePositionStore;

    bool noclipSpawn;
    int noclipWeapon;

    bool recalled;
    Position noclipBackup;

    uint release;
    uint lastNoclipAction;
    Position lerpFrom;
    Position lerpTo;

    bool autoRecall;
    int autoRecallStart;

    uint[] messageTimes;
    uint messageLock;
    bool firstMessage;

    int positionInterval;
    int recallHold;

    String lastFind;
    uint findIndex;

    String randmap;
    String randmapPattern;
    uint randmapMatches;

    Entity@ marker;

    void clear()
    {
        @this.client = null;

        this.positionInterval = POSITION_INTERVAL;
        this.recallHold = RECALL_HOLD;

        this.currentSector = 0;
        this.forceRespawn = 0;
        this.recalled = false;
        this.autoRecall = false;
        this.autoRecallStart = -1;
        this.release = 0;
        this.positionCycle = 0;
        this.noclipSpawn = false;

        this.freestylePositionStore.clear();
        this.noclipBackup.clear();
        this.lastNoclipAction = 0;
        this.lerpFrom.saved = false;
        this.lerpTo.saved = false;

        this.messageTimes.resize( MAX_FLOOD_MESSAGES );
        this.firstMessage = true;
        this.messageLock = 0;
        for ( int i = 0; i < MAX_FLOOD_MESSAGES; i++ )
            this.messageTimes[i] = 0;

        this.lastFind = "";
        this.findIndex = 0;

        this.randmap = "";
        this.randmapPattern = "";
        this.randmapMatches = 0;

        @this.marker = null;
    }

    Player()
    {
        this.clear();
    }

    ~Player() {}

    String@ scoreboardEntry()
    {
        Entity@ ent = this.client.getEnt();
        int playerID = ( ent.isGhosting() && ( match.getState() == MATCH_STATE_PLAYTIME ) ) ? -( ent.playerNum + 1 ) : ent.playerNum;

        return "&p " + playerID + " " + ent.client.clanName + " " + ent.client.ping + " ";
    }

    void setQuickMenu()
    {
        String s = '';
        Position@ position = this.savedPosition();

        s += menuItems[MI_RESTART_RACE];

        if ( this.client.team != TEAM_SPECTATOR )
        {
            if ( this.client.getEnt().moveType == MOVETYPE_NOCLIP )
                s += menuItems[MI_NOCLIP_OFF];
            else
                s += menuItems[MI_NOCLIP_ON];
        }
        else
        {
            s += menuItems[MI_EMPTY];
        }
        s += menuItems[MI_SAVE_POSITION];
        if ( position.saved )
            s += menuItems[MI_LOAD_POSITION] +
                 menuItems[MI_CLEAR_POSITION];

        GENERIC_SetQuickMenu( this.client, s );
    }

    bool toggleNoclip()
    {
        Entity@ ent = this.client.getEnt();
        if ( pending_endmatch || match.getState() >= MATCH_STATE_POSTMATCH )
        {
            G_PrintMsg( ent, "Can't use noclip in overtime.\n" );
            return false;
        }
        if ( this.client.team == TEAM_SPECTATOR || ent.health <= 0 )
        {
            Vec3 origin = ent.origin;
            Vec3 angles = ent.angles;
            if ( this.client.team == TEAM_SPECTATOR )
            {
                this.client.team = TEAM_PLAYERS;
                G_PrintMsg( null, this.client.name + S_COLOR_WHITE + " joined the " + G_GetTeam( this.client.team ).name + S_COLOR_WHITE + " team.\n" );
            }
            this.noclipSpawn = true;
            this.respawn();
            ent.origin = origin;
            ent.angles = angles;
            return true;
        }

        if ( ent.moveType == MOVETYPE_PLAYER )
        {
            ent.moveType = MOVETYPE_NOCLIP;
            this.noclipWeapon = ent.weapon;
        }
        else
        {
            uint moveType = ent.moveType;
            ent.moveType = MOVETYPE_PLAYER;
            this.client.selectWeapon( this.noclipWeapon );
            if ( this.recalled && moveType == MOVETYPE_NONE )
            {
                if ( this.lerpTo.saved )
                {
                    this.applyPosition( this.lerpTo );
                    this.lerpFrom.saved = false;
                    this.lerpTo.saved = false;
                }
                else
                    this.applyPosition( this.savedPosition() );
                this.autoRecallStart = this.positionCycle;
            }
            this.noclipBackup.saved = false;
        }

        this.setQuickMenu();
        this.updateHelpMessage();

        return true;
    }

    PositionStore@ positionStore()
    {
            return freestylePositionStore;
    }

    Position@ savedPosition()
    {
        return this.positionStore().positions[0];
    }

    void applyPosition( Position@ position )
    {
        Entity@ ent = this.client.getEnt();

        ent.origin = position.location;
        ent.angles = position.angles;
        ent.health = position.health;
        this.client.armor = position.armor;
        if ( ent.moveType != MOVETYPE_NOCLIP )
            ent.set_velocity( position.velocity );
        this.currentSector = position.currentSector;

        if ( !position.skipWeapons )
        {
            this.client.inventoryClear();
            for ( int i = WEAP_NONE + 1; i < WEAP_TOTAL; i++ )
            {
                if ( position.weapons[i] )
                    this.client.inventoryGiveItem( i );
                Item@ item = G_GetItem( i );
                this.client.inventorySetCount( item.ammoTag, position.ammos[i] );
            }
            for ( int i = POWERUP_QUAD; i < POWERUP_TOTAL; i++ )
                this.client.inventorySetCount( i, position.powerups[i - POWERUP_QUAD] );
            this.client.selectWeapon( position.weapon );
        }

        ent.teleported = true;
    }

    bool loadPosition( String name, Verbosity verbosity )
    {
        Entity@ ent = this.client.getEnt();

        this.noclipBackup.saved = false;

        PositionStore@ store = this.positionStore();
        Position@ position = store.get( name );

        if ( @position == null || !position.saved )
        {
            if ( verbosity == Verbosity_Verbose )
                G_PrintMsg( ent, "No position has been saved yet.\n" );
            return false;
        }

        this.applyPosition( position );

        if ( position.recalled )
        {
            this.recalled = true;
            this.autoRecallStart = this.positionCycle;
        }
        else
            this.recalled = false;

        if ( name != "" )
            store.set( "", position );

        this.updateHelpMessage();

        return true;
    }

    bool recallPosition( int offset )
    {
        Entity@ ent = this.client.getEnt();
        if ( this.client.team == TEAM_SPECTATOR )
        {
            G_PrintMsg( ent, "Position recall is not available in spectator mode.\n" );
            return false;
        }

        if ( !this.noclipBackup.saved )
        {
            this.noclipBackup.copy( this.currentPosition() );
            this.noclipBackup.saved = true;
            ent.moveType = MOVETYPE_NONE;
            G_CenterPrintMsg( ent, S_COLOR_CYAN + "Entered recall mode" );
        }

        this.positionCycle += offset;

        Position@ saved = this.savedPosition();
        saved.saved = true;
        saved.recalled = true;
        this.recalled = true;
        saved.skipWeapons = false;

        this.setQuickMenu();
        this.updateHelpMessage();

        return true;
    }

    Position@ currentPosition()
    {
        Position@ result = Position();
        result.saved = false;
        result.recalled = false;
        Client@ ref = this.client;
        if ( this.client.team == TEAM_SPECTATOR && this.client.chaseActive && this.client.chaseTarget != 0 )
            @ref = G_GetEntity( this.client.chaseTarget ).client;
        Entity@ ent = ref.getEnt();
        result.location = ent.origin;
        result.angles = ent.angles;
        result.velocity = ent.get_velocity();
        result.health = ent.health;
        result.armor = ref.armor;
        result.skipWeapons = false;
        result.currentSector = this.currentSector;
        for ( int i = WEAP_NONE + 1; i < WEAP_TOTAL; i++ )
        {
            result.weapons[i] = ref.canSelectWeapon( i );
            Item@ item = G_GetItem( i );
            result.ammos[i] = ref.inventoryCount( item.ammoTag );
        }
        for ( int i = POWERUP_QUAD; i < POWERUP_TOTAL; i++ )
            result.powerups[i - POWERUP_QUAD] = ref.inventoryCount( i );
        result.weapon = ( ent.moveType == MOVETYPE_NOCLIP || ent.moveType == MOVETYPE_NONE ) ? this.noclipWeapon : ref.pendingWeapon;
        return result;
    }

    bool savePosition( String name )
    {
        Client@ ref = this.client;
        if ( this.client.team == TEAM_SPECTATOR && this.client.chaseActive && this.client.chaseTarget != 0 )
            @ref = G_GetEntity( this.client.chaseTarget ).client;
        Entity@ ent = ref.getEnt();

        if ( ent.health <= 0 )
        {
            G_PrintMsg( ent, "You can only save your position while alive.\n" );
            return false;
        }

        PositionStore@ store = this.positionStore();
        Position@ position = store.get( name );
        if( @position == null )
            @position = Position();

        position.velocity = HorizontalVelocity( position.velocity );
        float speed;
        if ( position.saved && !position.recalled )
            speed = position.velocity.length();
        else
            speed = 0;

        position.copy( this.currentPosition() );
        position.saved = true;
        position.recalled = false;

        Vec3 a, b, c;
        position.angles.angleVectors( a, b, c );
        a = HorizontalVelocity( a );
        a.normalize();
        position.velocity = a * speed;

        position.skipWeapons = ref.team == TEAM_SPECTATOR;

        if ( !store.set( name, position ) )
        {
            G_PrintMsg( this.client.getEnt(), "No free position slot available.\n" );
            return false;
        }

        this.setQuickMenu();

        return true;
    }

    void listPositions()
    {
        Entity@ ent = this.client.getEnt();
        PositionStore@ store = this.positionStore();
        for ( uint i = 0; i < store.positions.length; i++ )
        {
            if( store.positions[i].saved )
            {
                if ( store.names[i] == "" )
                    G_PrintMsg( ent, "Main position saved\n" );
                else
                    G_PrintMsg( ent, "Additional position: '" + store.names[i] + "'\n" );
            }
        }
    }

    bool clearPosition( String name )
    {
        this.positionStore().remove( name );
        this.setQuickMenu();

        return true;
    }

    uint timeStamp()
    {
        return this.client.uCmdTimeStamp;
    }

    void checkRelease()
    {
        if ( this.release > 1 )
            this.release -= 1;
        else if ( this.release == 1 )
        {
            this.client.getEnt().moveType = MOVETYPE_PLAYER;
            this.loadPosition( "", Verbosity_Silent );
            this.release = 0;
        }
    }

    int getSpeed()
    {
        return int( HorizontalSpeed( this.client.getEnt().velocity ) );
    }

    void checkNoclipAction()
    {
        Entity@ ent = this.client.getEnt();

        if ( this.client.team == TEAM_SPECTATOR || ( ent.moveType != MOVETYPE_NOCLIP && ent.moveType != MOVETYPE_NONE ) || this.release > 0 || ent.health <= 0 )
            return;

        uint keys = this.client.pressedKeys;

        if ( keys & Key_Attack != 0 && keys & Key_Special != 0 && ent.moveType == MOVETYPE_NOCLIP )
        {
            Vec3 mins( 0 );
            Vec3 maxs( 0 );
            Vec3 offset( 0, 0, ent.viewHeight );
            Vec3 origin = ent.origin + offset;
            Vec3 a, b, c;
            ent.angles.angleVectors( a, b, c );
            a.normalize();
            Trace tr;
            float pull = 1.0f - pow( 1.0f - POINT_PULL, frameTime );
            if ( tr.doTrace( origin, mins, maxs, origin + a * POINT_DISTANCE, ent.entNum, MASK_PLAYERSOLID | MASK_WATER ) && tr.fraction * POINT_DISTANCE > PULL_MARGIN )
                ent.origin = origin * ( 1.0 - pull ) + tr.endPos * pull - offset;
            return;
        }

        uint passed = levelTime - this.lastNoclipAction;
        if ( passed < RECALL_ACTION_TIME )
        {
            if ( this.lerpTo.saved )
            {
                float lerp = float( passed ) / float( RECALL_ACTION_TIME );
                this.applyPosition( Lerp( this.lerpFrom, lerp, this.lerpTo ) );
            }
            return;
        }

        if ( this.lerpTo.saved )
        {
            this.applyPosition( this.lerpTo );
            this.lerpFrom.saved = false;
            this.lerpTo.saved = false;
        }

        this.lastNoclipAction = levelTime;

        if ( keys & Key_Attack != 0 )
        {
            if ( this.noclipBackup.saved )
            {
                ent.moveType = MOVETYPE_NOCLIP;
                this.applyPosition( this.noclipBackup );
                ent.set_velocity( Vec3() );
                this.noclipBackup.saved = false;
                this.recalled = false;
                G_CenterPrintMsg( ent, S_COLOR_CYAN + "Left recall mode" );
                this.updateHelpMessage();
            }
            else
                this.recallPosition( 0 );
        }
        else if ( keys & Key_Backward != 0 && this.noclipBackup.saved )
        {
            if ( this.positionCycle == 0 )
                this.recallPosition( -1 );
            else
            {
                this.lerpFrom.copy( this.savedPosition() );
                this.recallPosition( -1 );
                this.lerpTo.copy( this.savedPosition() );
                this.applyPosition( lerpFrom );
            }
        }
        else if ( keys & Key_Left != 0 && this.noclipBackup.saved )
        {
            if ( this.positionCycle < RECALL_ACTION_JUMP )
            {
                this.recallPosition( -this.positionCycle - 1 );
            }
            else
            {
                this.lerpFrom.copy( this.savedPosition() );
                this.recallPosition( -RECALL_ACTION_JUMP );
                this.lerpTo.copy( this.savedPosition() );
                this.applyPosition( lerpFrom );
            }
        }
        else if ( keys & Key_Forward != 0 && this.noclipBackup.saved )
        {
            this.lerpFrom.copy( this.savedPosition() );
            this.recallPosition( 1 );
            if ( this.positionCycle == 0 )
            {
                this.lerpFrom.saved = false;
            }
            else
            {
                this.lerpTo.copy( this.savedPosition() );
                this.applyPosition( this.lerpFrom );
            }
        }
        else if ( keys & Key_Right != 0 && this.noclipBackup.saved )
        {
            this.lerpFrom.copy( this.savedPosition() );
            this.recallPosition( RECALL_ACTION_JUMP );
            if ( this.positionCycle < RECALL_ACTION_JUMP )
            {
                this.lerpFrom.saved = false;
                this.recallPosition( -this.positionCycle );
            }
            else
            {
                this.lerpTo.copy( this.savedPosition() );
                this.applyPosition( this.lerpFrom );
            }
        }
        else
        {
            this.lastNoclipAction = 0;
        }
    }

    void spawn( int oldTeam, int newTeam )
    {
        this.forceRespawn = 0;

        this.setQuickMenu();
        this.updateHelpMessage();

        Entity@ ent = this.client.getEnt();

        if ( ent.isGhosting() )
            return;

        // set player movement to pass through other players
        this.client.pmoveFeatures = this.client.pmoveFeatures | PMFEAT_GHOSTMOVE;

        if ( gametype.isInstagib )
            this.client.inventoryGiveItem( WEAP_INSTAGUN );
        else
            this.client.inventorySetCount( WEAP_GUNBLADE, 1 );

        // select rocket launcher if available
        if ( this.client.canSelectWeapon( WEAP_ROCKETLAUNCHER ) )
            this.client.selectWeapon( WEAP_ROCKETLAUNCHER );
        else
            this.client.selectWeapon( -1 ); // auto-select best weapon in the inventory

        this.loadPosition( "", Verbosity_Silent );

        if ( this.noclipSpawn )
        {
            this.recalled = false;
            ent.moveType = MOVETYPE_NOCLIP;
            ent.velocity = Vec3();
            this.noclipWeapon = this.client.pendingWeapon;
            this.noclipSpawn = false;
        }

        if ( this.recalled )
        {
            ent.moveType = MOVETYPE_NONE;
            this.updateHelpMessage();
            this.release = this.recallHold;
        }

        this.updateHelpMessage();
    }

    void updateHelpMessage()
    {
        // msc: permanent practicemode message
        Client@ ref = this.client;
        if ( ref.team == TEAM_SPECTATOR && ref.chaseActive && ref.chaseTarget != 0 )
            @ref = G_GetEntity( ref.chaseTarget ).client;
        Player@ refPlayer = RACE_GetPlayer( ref );
        if ( ref.team != TEAM_SPECTATOR )
        {
            if ( refPlayer.recalled )
                this.client.setHelpMessage( recallModeMsg );
            else
            {
                if ( ref.getEnt().moveType == MOVETYPE_NOCLIP )
                    this.client.setHelpMessage( noclipModeMsg );
                else
                    this.client.setHelpMessage( 0 );
            }
        }
        else
        {
            this.client.setHelpMessage( 0 );
        }
    }

    void think()
    {
        Client@ client = this.client;
        Entity@ ent = client.getEnt();

        client.setHUDStat( STAT_TIME_ALPHA, -9999 );
        client.setHUDStat( STAT_TIME_BETA, -9999 );

        this.checkNoclipAction();
        this.checkRelease();

        this.updateHelpMessage();

        if ( client.state() >= CS_SPAWNED && ent.team != TEAM_SPECTATOR )
        {
            if ( ent.health > ent.maxHealth )
            {
                ent.health -= ( frameTime * 0.001f );
                // fix possible rounding errors
                if ( ent.health < ent.maxHealth )
                    ent.health = ent.maxHealth;
            }
        }
    }

    void scheduleRespawn()
    {
        this.forceRespawn = levelTime + 5000;
    }

    void respawn()
    {
        this.forceRespawn = 0;
        this.client.respawn( false );
    }

    bool recallExit()
    {
        if ( this.client.team == TEAM_SPECTATOR )
        {
            G_PrintMsg( this.client.getEnt(), "Not available in spectator mode.\n" );
            return false;
        }

        if ( !this.noclipBackup.saved )
            return true;

        Entity@ ent = this.client.getEnt();
        ent.moveType = MOVETYPE_NOCLIP;
        this.applyPosition( this.noclipBackup );
        ent.set_velocity( Vec3() );
        this.noclipBackup.saved = false;
        this.recalled = false;
        G_CenterPrintMsg( ent, S_COLOR_CYAN + "Left recall mode" );
        this.updateHelpMessage();
        return true;
    }

    bool recallInterval( String value )
    {
        Entity@ ent = this.client.getEnt();
        {
            int number = -1;
            if ( value != "" )
                number = value.toInt();
            if ( number < 0 )
                G_PrintMsg( ent, this.positionInterval + "\n" );
            else
                this.positionInterval = number;
        }
        return true;
    }

    bool recallDelay( String value )
    {
        Entity@ ent = this.client.getEnt();
        int number = -1;
        if ( value != "" )
            number = value.toInt();
        if ( number < 0 )
            G_PrintMsg( ent, this.recallHold + "\n" );
        else
        {
            if ( number < 2 )
                number = 2;
            this.recallHold = number;
        }
        return true;
    }

    Player@ oneMatchingPlayer( String pattern )
    {
        Player@[] matches = RACE_MatchPlayers( pattern );
        Entity@ ent = this.client.getEnt();

        if ( matches.length() == 0 )
        {
            G_PrintMsg( ent, "No players matched.\n" );
            return null;
        }
        else if ( matches.length() > 1 )
        {
            G_PrintMsg( ent, "Multiple players matched:\n" );
            for ( uint i = 0; i < matches.length(); i++ )
                G_PrintMsg( ent, matches[i].client.name + S_COLOR_WHITE + "\n" );
            return null;
        }
        else
            return matches[0];
    }

    bool recallFake( uint time )
    {
        Position@ position = this.savedPosition();

        if ( !position.saved )
        {
            G_PrintMsg( this.client.getEnt(), "No position saved.\n" );
            return false;
        }
        position.recalled = true;
        position.currentTime = time;

        return true;
    }

    bool recallStart()
    {
        return this.recallPosition( -this.positionCycle );
    }

    bool recallEnd()
    {
        return this.recallPosition( -this.positionCycle - 1 );
    }

    bool recallExtend( String option )
    {
        if ( option == "on" )
            this.autoRecall = true;
        else if ( option == "off" )
            this.autoRecall = false;
        else
            this.autoRecall = !this.autoRecall;
        Entity@ ent = this.client.getEnt();
        if ( this.autoRecall )
            G_PrintMsg( ent, "Auto recall extend ON.\n" );
        else
            G_PrintMsg( ent, "Auto recall extend OFF.\n" );
        return true;
    }

    bool recallCheckpoint( int cp )
    {
        int index = -1;
        if ( index != -1 )
        {
            return this.recallPosition( index - this.positionCycle );
        }
        else
        {
            G_PrintMsg( this.client.getEnt(), "Not found.\n" );
            return false;
        }
    }

    bool recallWeapon( uint weapon )
    {
        int index = -1;
        if ( index != -1 )
        {
            return this.recallPosition( index - this.positionCycle );
        }
        else
        {
            G_PrintMsg( this.client.getEnt(), "Not found.\n" );
            return false;
        }
    }

    bool findPosition( String entity, String parameter )
    {
        Entity@ ent = this.client.getEnt();

        if ( entity == "" )
        {
            this.showMapStats();
            G_PrintMsg( ent, "Usage: /position find <start|finish|rl|gl|pg|push|door|button|tele|slick> [info]\n" );
            return false;
        }

        if ( parameter == "info" )
        {
            EntityList@ list = entityFinder.allEntities( entity );
            if ( list.isEmpty() )
            {
                G_PrintMsg( ent, "No matching entity found.\n" );
                return false;
            }
            uint len = list.length();
            bool small = len < BIG_LIST;
            bool single = len == 1;
            if ( !small )
                G_PrintMsg( ent, "Omitting target info as this is a big list\n" );
            while ( !list.isEmpty() )
            {
                Entity@ current = list.getEnt( 0 );
                G_PrintMsg( ent, "entity " + current.entNum + ": " + current.classname + " @ " + ent.origin.x + " " + ent.origin.y + " " + ent.origin.z + "\n" );
                if ( small )
                {
                    if ( single )
                    {
                        Vec3 mins, maxs;
                        current.getSize( mins, maxs );
                        G_PrintMsg( ent, "    mins: " + mins.x + " " + mins.y + " " + mins.z + "\n" );
                        G_PrintMsg( ent, "    maxs: " + maxs.x + " " + maxs.y + " " + maxs.z + "\n" );
                        G_PrintMsg( ent, "    type: " + current.type + "\n" );
                        G_PrintMsg( ent, "    solid: " + current.solid + "\n" );
                        G_PrintMsg( ent, "    svflags: " + current.svflags + "\n" );
                        G_PrintMsg( ent, "    clipMask: " + current.clipMask + "\n" );
                        G_PrintMsg( ent, "    spawnFlags: " + current.spawnFlags + "\n" );
                        G_PrintMsg( ent, "    frame: " + current.frame + "\n" );
                        G_PrintMsg( ent, "    count: " + current.count + "\n" );
                        G_PrintMsg( ent, "    wait: " + current.wait + "\n" );
                        G_PrintMsg( ent, "    delay: " + current.delay + "\n" );
                        G_PrintMsg( ent, "    health: " + current.health + "\n" );
                        G_PrintMsg( ent, "    maxHealth: " + current.maxHealth + "\n" );
                    }
                    array<Entity@>@ targeting = current.findTargeting();
                    for ( uint i = 0; i < targeting.length; i++ )
                        G_PrintMsg( ent, "    targetted by " + targeting[i].entNum + ": " + targeting[i].classname + "\n" );
                    array<Entity@>@ targets = current.findTargets();
                    for ( uint i = 0; i < targets.length; i++ )
                        G_PrintMsg( ent, "    target " + targets[i].entNum + ": " + targets[i].classname + "\n" );
                }
                @list = list.drop( 1 );
            }
        }
        else
        {
            if ( entity == this.lastFind )
                this.findIndex++;
            else
                this.findIndex = 0;
            Vec3 origin = entityFinder.find( entity, this.findIndex );
            if ( origin == NO_POSITION )
            {
                G_PrintMsg( ent, "No matching entity found.\n" );
                return false;
            }
            this.lastFind = entity;

            ent.origin = origin;
        }

        return true;
    }

    bool joinPosition( String pattern )
    {
        Entity@ ent = this.client.getEnt();

        Player@ match = this.oneMatchingPlayer( pattern );
        if ( @match == null )
            return false;

        this.applyPosition( match.currentPosition() );
        ent.set_velocity( Vec3() );

        return true;
    }

    bool positionSpeed( String speedStr, String name )
    {
        Position@ position = this.freestylePositionStore.get( name );
        if ( @position == null )
        {
            G_PrintMsg( this.client.getEnt(), "No such position set.\n" );
            return false;
        }
        if ( !position.saved )
        {
            position.copy( this.currentPosition() );
            position.saved = true;
        }
        float speed = 0;
        bool doAdd = speedStr.locate( "+", 0 ) == 0;
        bool doSubtract = speedStr.locate( "-", 0 ) == 0;
        if ( position.saved && ( doAdd || doSubtract ) )
        {
            speed = HorizontalSpeed( position.velocity );
            float diff = speedStr.substr( 1 ).toFloat();
            if ( doAdd )
                speed += diff;
            else
                speed -= diff;
        }
        else
            speed = speedStr.toFloat();
        Vec3 a, b, c;
        position.angles.angleVectors( a, b, c );
        a = HorizontalVelocity( a );
        a.normalize();
        position.velocity = a * speed;
        position.recalled = false;
        return true;
    }

    bool setMarker( String copy )
    {
        Entity@ ent = this.client.getEnt();
        Entity@ ref = ent;

        if ( copy != "" )
        {
            Player@ match = this.oneMatchingPlayer( copy );
            if ( @match == null )
            {
                this.marker.unlinkEntity();
                this.marker.freeEntity();
                @this.marker = null;
                return false;
            }
            @ref = match.marker;
            if ( @ref == null )
            {
                this.client.printMessage( "Player does not have a marker set.\n" );
                return false;
            }
        }

        Entity@ dummy = G_SpawnEntity( "dummy" );
        dummy.modelindex = G_ModelIndex( "models/players/bigvic/tris.iqm" );
        dummy.svflags |= SVF_ONLYOWNER;
        dummy.svflags &= ~SVF_NOCLIENT;
        dummy.ownerNum = ent.entNum;
        dummy.origin = ref.origin;
        dummy.angles = Vec3( 0, ref.angles.y, 0 );

        if ( @this.marker != null )
        {
            this.marker.unlinkEntity();
            this.marker.freeEntity();
        }

        dummy.linkEntity();

        @this.marker = dummy;

        return true;
    }

    void showMapStats()
    {
        String msg = "";
        uint numRLs = entityFinder.rls.length();
        uint numGLs = entityFinder.gls.length();
        uint numPGs = entityFinder.pgs.length();
        if ( numRLs + numGLs + numPGs == 0 )
            msg = "strafe";
        else
        {
            if ( numRLs > 0 )
            {
                msg += "rl(" + numRLs + ")";
                if ( numGLs + numPGs > 0 )
                    msg += ", ";
            }
            if ( numGLs > 0 )
            {
                msg += "gl(" + numGLs + ")";
                if ( numPGs > 0 )
                    msg += ", ";
            }
            if ( numPGs > 0 )
                msg += "pg(" + numPGs + ")";
        }
        if ( entityFinder.slicks.length() > 0 )
            msg += ", slick";
        uint numPushes = entityFinder.pushes.length();
        uint numDoors = entityFinder.doors.length();
        uint numButtons = entityFinder.buttons.length();
        uint numTeles = entityFinder.teles.length();
        if ( numPushes > 0 )
            msg += ", push(" + numPushes + ")";
        if ( numDoors > 0 )
            msg += ", doors(" + numDoors + ")";
        if ( numButtons > 0 )
            msg += ", buttons(" + numButtons + ")";
        if ( numTeles > 0 )
            msg += ", teles(" + numTeles + ")";
        if ( entityFinder.starts.length() == 0 )
            msg += ", " + S_COLOR_RED + "no start" + S_COLOR_WHITE;
        if ( entityFinder.finishes.length() == 0 )
            msg += ", " + S_COLOR_RED + "no finish" + S_COLOR_WHITE;
        G_PrintMsg( this.client.getEnt(), S_COLOR_GREEN + "Map stats: " + S_COLOR_WHITE + msg + "\n" );
    }

    String randomMap( String pattern, bool pre )
    {
        pattern = pattern.removeColorTokens().tolower();
        if ( pattern == "*" )
            pattern = "";

        if ( !pre && this.randmap != "" && this.randmapPattern == pattern )
            return this.randmap;

        Cvar mapname( "mapname", "", 0 );
        String current = mapname.string;

        String[] maps = GetMapsByPattern( pattern, current );

        if ( maps.length() == 0 )
        {
            this.client.printMessage( "No matching maps\n" );
            return "";
        }

        uint matches = maps.length();
        String result = maps[randrange(matches)];
        if ( pre )
        {
            this.randmap = result;
            this.randmapPattern = pattern;
        }
        else
        {
            this.randmap = "";
        }
        this.randmapMatches = matches;
        return result;
    }
}

Player@ RACE_GetPlayer( Client@ client )
{
    if ( @client == null || client.playerNum < 0 )
        return null;

    Player@ player = players[client.playerNum];
    @player.client = client;

    return player;
}

Player@[] RACE_MatchPlayers( String pattern )
{
    pattern = pattern.removeColorTokens().tolower();

    Player@[] playerList;
    for ( int i = 0; i < maxClients; i++ )
    {
        Client@ client = @G_GetClient(i);
        String clean = client.name.removeColorTokens().tolower();

        if ( PatternMatch( clean, pattern ) )
            playerList.push_back( RACE_GetPlayer( client ) );
    }
    return playerList;
}
