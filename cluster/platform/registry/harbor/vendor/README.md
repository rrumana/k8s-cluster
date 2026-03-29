Vendored Harbor Helm chart location.

Before committing or syncing `harbor-app`, place chart version `1.18.3` here with:

  helm pull harbor --repo https://helm.goharbor.io --version 1.18.3 --untar --untardir cluster/platform/registry/harbor/vendor

This keeps Harbor's bootstrap chart source in git instead of making Harbor depend on a live external chart repo or on Harbor serving its own chart.
