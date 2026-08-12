-- next sereparate the admin perms and the authority check for humanoid?
-- these are causing script prioritory issues because it fetchs game api later in the script after config for admin perms 



local KickMessage = {

	--- IDs used in the anti-cheat to display kick messages.
	KickIDs = {
		Noclipping = {
			ID = "0001",
			Message = "Player assumed to be noclipping.",
		},
		Flying = {
			ID = "0002",
			Message = "Player assumed to be flying.",
		},
		TPing = {
			ID = "0003",
			Message = "Player assumed to be teleporting across great distances.",
		},
		SpeedHacking = {
			ID = "0004",
			Message = "Player assumed to be speed hacking.",
		},
	},
	AdminPerms = {
		{
			Name = "MrFuzzy",
			UserId = nil,
			Rank = "Modeler/Music",
		},
		{
			Name = "EvershadeBlight",
			UserId = nil,
			Rank = "Owner",
		},
	},

	--don't add anything in here
	Commands = {},
	CommandDebounce = {},
}