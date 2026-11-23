"""Read-only SearchTimeline adapter for the project-local twitter-cli."""

import json
import os
import re
import sys
from urllib.parse import urlsplit
from urllib.request import urlopen

from twitter_cli import cli, client, graphql


class SearchClient(client.TwitterClient):
    def _ensure_client_transaction(self):
        self._ct_init_attempted = True
        session = client._get_cffi_session()
        headers = client._gen_ct_headers()
        response = session.get(
            "https://x.com/home", headers=headers, timeout=5,
            cookies={"auth_token": os.environ["TWITTER_AUTH_TOKEN"], "ct0": os.environ["TWITTER_CT0"]},
        )
        response.raise_for_status()
        page = client.bs4.BeautifulSoup(response.content, "html.parser")
        bundle_url = client.get_ondemand_file_url(response=page)
        bundle = urlsplit(bundle_url)
        if bundle.scheme != "https" or bundle.netloc != "abs.twimg.com":
            raise ValueError("unexpected X script origin")
        script = session.get(bundle_url, timeout=5)
        script.raise_for_status()
        self._client_transaction = client.ClientTransaction(
            home_page_response=page, ondemand_file_response=script.text,
        )


def main():
    try:
        with urlopen(graphql.TWITTER_OPENAPI_URL, timeout=5) as response:
            operation = json.load(response)["SearchTimeline"]
        query_id = operation["queryId"]
        features = operation["features"]
        if not re.fullmatch(r"[A-Za-z0-9_-]{10,64}", query_id) or not isinstance(features, dict) or not features:
            raise ValueError("invalid SearchTimeline metadata")
    except Exception:
        print(json.dumps({"ok": False, "error": {"code": "search_metadata_unavailable"}}))
        return 2

    graphql.FALLBACK_QUERY_IDS["SearchTimeline"] = query_id
    graphql.FEATURES.clear()
    graphql.FEATURES.update(features)
    cli.TwitterClient = SearchClient
    cli.cli(args=["search", "--type", "Latest", "-n", "10", "--json", "--", sys.argv[1]])
    return 0


if __name__ == "__main__":
    sys.exit(main())
