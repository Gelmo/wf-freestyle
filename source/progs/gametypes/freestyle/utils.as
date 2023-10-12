enum Keys {
    Key_Forward = 1,
    Key_Backward = 2,
    Key_Left = 4,
    Key_Right = 8,
    Key_Attack = 16,
    Key_Jump = 32,
    Key_Crouch = 64,
    Key_Special = 128,
};

enum Wildcard {
    Wildcard_No,
    Wildcard_Yes,
};

bool PatternMatch( String str, String pattern, Wildcard wildcard = Wildcard_No )
{
    if ( wildcard == Wildcard_Yes && ( pattern == "*" || pattern == "" ) ) return true;
    return str.locate( pattern, 0 ) < str.length();
}

Vec3 Centre( Entity@ ent )
{
    Vec3 mins, maxs;
    ent.getSize( mins, maxs );
    return ent.origin + 0.5 * mins + 0.5 * maxs;
}

String[] GetMapsByPattern( String@ pattern, String@ ignore = null )
{
    String[] maps;

    const String@ map;
    pattern = pattern.removeColorTokens().tolower();
    if ( pattern == "*" )
        pattern = "";
    
    uint i = 0;
    while( true )
    {
        @map = ML_GetMapByNum( i++ );
        if ( @map == null )
            break;
        String clean_map = map.removeColorTokens().tolower();
        if ( @ignore != null && map == ignore )
            continue;
        if ( PatternMatch( clean_map, pattern, Wildcard_Yes ) )
        {
            maps.insertLast( map );
        }
    }

    return maps;
}
