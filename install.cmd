@echo off
rem Link mod\ClaudeBot into your Zomboid mods folder (a junction, no admin needed).
mklink /J "%USERPROFILE%\Zomboid\mods\ClaudeBot" "%~dp0mod\ClaudeBot"
rem Install the pz-player agent for Claude Code sessions started outside this folder.
rem Re-run after pulling changes to it.
if not exist "%USERPROFILE%\.claude\agents" mkdir "%USERPROFILE%\.claude\agents"
copy /Y "%~dp0.claude\agents\pz-player.md" "%USERPROFILE%\.claude\agents\pz-player.md"
