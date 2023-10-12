enum eMenuItems
{
    MI_EMPTY,
    MI_RESTART_RACE,
    MI_NOCLIP_ON,
    MI_NOCLIP_OFF,
    MI_SAVE_POSITION,
    MI_LOAD_POSITION,
    MI_CLEAR_POSITION
};

array<const String@> menuItems = {
    '"" ""',
    '"Restart race" "kill"',
    '"Enable noclip mode" "noclip" ',
    '"Disable noclip mode" "noclip" ',
    '"Save position" "position save" ',
    '"Load saved position" "position load" ',
    '"Clear saved position" "position clear" '
};
