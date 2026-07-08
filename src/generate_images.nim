import std/envvars
import std/strutils
import std/sequtils
import github_stats

proc main() =
  var access_token: string = getEnv("ACCESS_TOKEN")
  if access_token == "":
    raise newException(OSError, "GitHub access token is required to proceed!")

  var languages: string = getEnv("EXCLUDED_LANGS")
  var excluded_langs: seq[string] = languages.split(',').map(proc(
      x: string): string = return strip(x))

  var repositories: string = getEnv("EXCLUDED_REPOS")
  var excluded_repos: seq[string] = repositories.split(',').map(proc(
      x: string): string = return strip(x))

  var gh_stats: Stats = newStats(access_token, excluded_langs, excluded_repos)

  gh_stats.getContributions()
  gh_stats.getStatistics()
  gh_stats.generateLanguages()
  gh_stats.generateOwerview()

when isMainModule:
  main()
