-- Hand-ported from pret/pokered scripts/RedsHouse1F.asm.
-- Mom (RedsHouse1FMomText, text_asm) heals the party and shows the
-- "you should rest" / "looking great" dialogue.  The intro "wake up"
-- branch is tied to the unported intro cutscene, so the heal path is used.

return {
  talk = {
    TEXT_REDSHOUSE1F_MOM = {
      { "face_player" },
      { "show_text", "_RedsHouse1FMomYouShouldRestText" },
      { "heal_party" },
      { "show_text", "_RedsHouse1FMomLookingGreatText" },
    },
  },
}
