import std/httpclient
import std/json
import std/tables
import std/algorithm
import std/strformat
import std/strutils
import std/sequtils
import std/sets
import std/private/osdirs

type Stats* = object
  name: string
  access_token: string
  excluded_langs: seq[string]
  excluded_repos: seq[string]
  total_contributions: int
  total_contributed_repo: int
  total_stars: int
  total_forks: int
  total_views: int
  sizes: Table[string, int]
  colors: Table[string, string]
  languages: seq[(string, float)]

proc newStats*(access_token: string, excluded_langs: seq[string],
    excluded_repos: seq[string]): Stats =
  result.name = ""
  result.access_token = access_token
  result.excluded_langs = excluded_langs
  result.excluded_repos = excluded_repos
  result.total_contributions = 0
  result.total_contributed_repo = 0
  result.total_stars = 0
  result.total_forks = 0
  result.total_views = 0
  result.sizes = initTable[string, int]()
  result.colors = initTable[string, string]()
  result.languages = @[]

# TODO - add pageInfo to see if there's more
proc queryBuilder(years: seq[int]): string =
  var by_years = years.map(proc (year: int): string =
    return fmt"""
    year{year}: contributionsCollection(
      from: "{year}-01-01T00:00:00Z",
      to: "{year+1}-01-01T00:00:00Z"
    ) {{
      contributionCalendar {{
        totalContributions
      }}
      commitContributionsByRepository(maxRepositories: 100) {{
        repository {{
          nameWithOwner
        }}
      }}
    }}
    """
  ).join("\n")

  return fmt"""
  query {{
    viewer {{
      {by_years}
    }}
  }}
  """

proc getContributions*(s: var Stats) =
  var client = newHttpClient()
  client.headers = newHttpHeaders({
    "Content-Type": "application/json",
    "Authorization": fmt"Bearer {s.access_token}"
  })

  var endpoint = "https://api.github.com/graphql"

  var query = """
  query {
    viewer {
      name
      contributionsCollection {
        contributionYears
      }
    }
  }
  """

  var contributed_repos: HashSet[string] = initHashSet[string]()

  try:
    var payload = %*{
      "query": query
    }

    var response = client.request(endpoint, httpMethod = HttpPost,
        body = $payload)
    var jsonObject = parseJson(response.body)

    s.name = jsonObject["data"]["viewer"]["name"].getStr

    var contrib_years: seq[int]

    for item in jsonObject["data"]["viewer"]["contributionsCollection"]["contributionYears"]:
      contrib_years.add(item.getInt)

    contrib_years.reverse

    payload = %*{
      "query": queryBuilder(contrib_years)
    }

    response = client.request(endpoint, httpMethod = HttpPost,
        body = $payload)
    jsonObject = parseJson(response.body)

    for _, v in jsonObject["data"]["viewer"]:
      s.total_contributions += v["contributionCalendar"][
          "totalContributions"].getInt

      for repo in v["commitContributionsByRepository"]:
        contributed_repos.incl(repo["repository"]["nameWithOwner"].getStr)

    var repo_with_contributions: HashSet[string] = contributed_repos -
        toHashSet(s.excluded_repos)

    s.total_contributed_repo = repo_with_contributions.len
  except CatchableError as e:
    echo e.msg
    raise
  finally:
    client.close()

proc myCmp(x: (string, float), y: (string, float)): int =
  return cmp(x[1], y[1])

proc getStatistics*(s: var Stats) =
  var client = newHttpClient()
  client.headers = newHttpHeaders({
    "Content-Type": "application/json",
    "Authorization": fmt"Bearer {s.access_token}"
  })

  var endpoint = "https://api.github.com/graphql"

  var query = """
  query($after: String) {
    viewer {
      repositories(first: 100, after: $after, orderBy: { field: NAME, direction: ASC }) {
        nodes {
          nameWithOwner
          stargazerCount
          forkCount
          isPrivate
          isFork
          languages(
            first: 100,
            orderBy: { direction: DESC, field: SIZE }
          ) {
            edges {
              size
              node {
                name
                color
              }
            }
          }
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }
  """

  var after: string
  var hasNextPage: bool = true

  try:
    while hasNextPage:
      var payload = %*{
        "query": query,
        "variables": {
          "after": after
        }
      }

      var response = client.request(endpoint, httpMethod = HttpPost,
          body = $payload)
      var jsonObject = parseJson(response.body)
      hasNextPage = jsonObject["data"]["viewer"]["repositories"]["pageInfo"][
          "hasNextPage"].getBool
      after = jsonObject["data"]["viewer"]["repositories"]["pageInfo"][
          "endCursor"].getStr

      for item in jsonObject["data"]["viewer"]["repositories"]["nodes"]:
        s.total_stars += item["stargazerCount"].getInt
        s.total_forks += item["forkCount"].getInt
        var path: string = item["nameWithOwner"].getStr

        var jsonContent = client.getContent(
            fmt"https://api.github.com/repos/{path}/traffic/views")
        if jsonContent != "":
          var jsonObject = parseJson(jsonContent)
          s.total_views += jsonObject["count"].getInt

        if item["isFork"].getBool != true:
          for langs in item["languages"]["edges"]:
            s.sizes.mgetOrPut(langs["node"]["name"].getStr, 0) += langs["size"].getInt
            s.colors[langs["node"]["name"].getStr] = langs["node"]["color"].getStr

    var langs: HashSet[string] = toHashSet(s.sizes.keys.toSeq) - toHashSet(
        s.excluded_langs)
    var total_langs: float = 0.0

    for lang in langs:
      total_langs += float(s.sizes[lang])

    for lang in langs:
      s.languages.add((lang, 100*(float(s.sizes[lang])/total_langs)))

    s.languages.sort(myCmp, order = SortOrder.Descending)

  except CatchableError as e:
    echo e.msg
    raise
  finally:
    client.close()

proc generateLanguages*(s: Stats) =
  var progress: string
  var lang_list: string
  var delay: int = 150

  for i, (lang, prop) in s.languages.pairs:
    progress &= fmt"""
    <span style="background-color: {s.colors[lang]}; width: {prop:0.2f}%;" class="progress-item"></span>
    """

    lang_list &= fmt"""
    <li style="animation-delay: {i*delay}ms;">
      <svg xmlns="http://www.w3.org/2000/svg" class="octicon" style="fill:{s.colors[lang]};" viewBox="0 0 16 16" version="1.1" width="16" height="16">
        <path fill-rule="evenodd" d="M8 4a4 4 0 100 8 4 4 0 000-8z"></path>
      </svg>
      <span class="lang">{lang}</span>
      <span class="percent">{prop:0.2f}%</span>
    </li>
    """

  var content: string = readFile("templates/languages.svg")
  content = content.replace("{{ progress }}", progress)
  content = content.replace("{{ lang_list }}", lang_list)

  discard existsOrCreateDir("generated")
  writeFile("generated/languages.svg", content)

proc generateOwerview*(s: Stats) =
  var content: string = readFile("templates/overview.svg")
  content = content.replace("{{ name }}", s.name)
  content = content.replace("{{ stars }}", $s.total_stars)
  content = content.replace("{{ forks }}", $s.total_forks)
  content = content.replace("{{ contributions }}", $s.total_contributions)
  content = content.replace("{{ views }}", $s.total_views)
  content = content.replace("{{ repos }}", $s.total_contributed_repo)

  discard existsOrCreateDir("generated")
  writeFile("generated/overview.svg", content)


# var gh_stats: Stats = newStats("Joy", ACCESS_TOKEN, @[], @[])
# gh_stats.getContributions()
# gh_stats.getStatistics()
# gh_stats.generateLanguages()
# gh_stats.generateOwerview()
# echo gh_stats
