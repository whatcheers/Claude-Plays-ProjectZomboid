@echo off
rem Link this project into the Zomboid user folder (junctions, no admin needed).
mklink /J "%USERPROFILE%\Zomboid\mods\ClaudeBot" "%~dp0mod\ClaudeBot"
mklink /J "%USERPROFILE%\Zomboid\Lua\claudebot" "%~dp0runtime"
