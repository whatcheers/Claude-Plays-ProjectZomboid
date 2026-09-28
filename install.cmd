@echo off
rem Link mod\ClaudeBot into your Zomboid mods folder (a junction, no admin needed).
mklink /J "%USERPROFILE%\Zomboid\mods\ClaudeBot" "%~dp0mod\ClaudeBot"
