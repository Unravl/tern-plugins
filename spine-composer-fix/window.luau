--!strict

-- Tern 0.8.3's reduced-transparency sheet paints every omp editor with an opaque `--pop-bg`
-- fill (!important). Reader draws the editor as a card, so that fits. Spine draws a full-width
-- composer band and clears the editor's own background, so the fill leaves a lighter, narrower
-- box inside the band. This restores Spine's transparent editor; other chat styles are untouched.
tern.css("spine-editor", [[
@media (prefers-reduced-transparency: reduce) {
  .sf-chat-spine .sf-col[data-role^='omp.editor'] {
    background: none !important;
  }
}
]])
