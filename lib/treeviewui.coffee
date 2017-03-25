{CompositeDisposable} = require 'atom'
path = require 'path'
fs = require 'fs-plus'
utils = require './utils'

flowIconMap =
  feature: 'puzzle'
  hotfix: 'flame'
  develop: 'home'
  master: 'verified'

module.exports = class TreeViewUI

  roots: null
  repositoryMap: null
  treeViewRootsMap: null
  subscriptions: null
  ENUM_UPDATE_STATUS =
    { NOT_UPDATING: 0, UPDATING: 1, QUEUED: 2, QUEUED_RESET: 3 }
  statusUpdatingRoots = ENUM_UPDATE_STATUS.NOT_UPDATING

  constructor: (@treeView, @repositoryMap) ->
    # Read configuration
    @showProjectModifiedStatus =
      atom.config.get 'tree-view-git-status.showProjectModifiedStatus'
    @showBranchLabel =
      atom.config.get 'tree-view-git-status.showBranchLabel'
    @showCommitsAheadLabel =
      atom.config.get 'tree-view-git-status.showCommitsAheadLabel'
    @showCommitsBehindLabel =
      atom.config.get 'tree-view-git-status.showCommitsBehindLabel'
    @gitFlowEnabled =
      atom.config.get 'tree-view-git-status.git_flow.enabled'
    @gitFlowDisplayType =
      atom.config.get 'tree-view-git-status.git_flow.display_type'

    @subscriptions = new CompositeDisposable
    @treeViewRootsMap = new Map

    # Bind against events which are causing an update of the tree view
    @subscribeUpdateConfigurations()
    @subscribeUpdateTreeView()

    # Trigger inital update of all root nodes
    @updateRoots true

  destruct: ->
    @clearTreeViewRootMap()
    @subscriptions?.dispose()
    @subscriptions = null
    @treeViewRootsMap = null
    @repositoryMap = null
    @roots = null

  subscribeUpdateTreeView: ->
    @subscriptions.add(
      atom.project.onDidChangePaths =>
        @updateRoots true
    )
    @subscriptions.add(
      atom.config.onDidChange 'tree-view.hideVcsIgnoredFiles', =>
        @updateRoots true
    )
    @subscriptions.add(
      atom.config.onDidChange 'tree-view.hideIgnoredNames', =>
        @updateRoots true
    )
    @subscriptions.add(
      atom.config.onDidChange 'core.ignoredNames', =>
        @updateRoots true if atom.config.get 'tree-view.hideIgnoredNames'
    )
    @subscriptions.add(
      atom.config.onDidChange 'tree-view.sortFoldersBeforeFiles', =>
        @updateRoots true
    )

  subscribeUpdateConfigurations: ->
    @subscriptions.add(
      atom.config.observe 'tree-view-git-status.showProjectModifiedStatus',
        (newValue) =>
          if @showProjectModifiedStatus isnt newValue
            @showProjectModifiedStatus = newValue
            @updateRoots()
    )
    @subscriptions.add(
      atom.config.observe 'tree-view-git-status.showBranchLabel',
        (newValue) =>
          if @showBranchLabel isnt newValue
            @showBranchLabel = newValue
          @updateRoots()
    )
    @subscriptions.add(
      atom.config.observe 'tree-view-git-status.showCommitsAheadLabel',
        (newValue) =>
          if @showCommitsAheadLabel isnt newValue
            @showCommitsAheadLabel = newValue
            @updateRoots()
    )
    @subscriptions.add(
      atom.config.observe 'tree-view-git-status.showCommitsBehindLabel',
        (newValue) =>
          if @showCommitsBehindLabel isnt newValue
            @showCommitsBehindLabel = newValue
            @updateRoots()
    )
    @subscriptions.add(
      atom.config.observe 'tree-view-git-status.git_flow.enabled',
        (newValue) =>
          if @gitFlowEnabled isnt newValue
            @gitFlowEnabled = newValue
            @updateRoots()
    )
    @subscriptions.add(
      atom.config.observe 'tree-view-git-status.git_flow.display_type',
        (newValue) =>
          if @gitFlowDisplayType isnt newValue
            @gitFlowDisplayType = newValue
            @updateRoots()
    )

  setRepositories: (repositories) ->
    if repositories?
      @repositoryMap = repositories
      @updateRoots true

  clearTreeViewRootMap: ->
    @treeViewRootsMap?.forEach (root, rootPath) ->
      root.root?.classList?.remove('status-modified', 'status-added')
      customElements = root.customElements
      if customElements?.headerGitStatus?
        root.root?.header?.removeChild(customElements.headerGitStatus)
        customElements.headerGitStatus = null
    @treeViewRootsMap?.clear()

  updateRoots: (reset) ->
    return if not @repositoryMap?
    if statusUpdatingRoots is ENUM_UPDATE_STATUS.NOT_UPDATING
      statusUpdatingRoots = ENUM_UPDATE_STATUS.UPDATING
      @roots = @treeView.roots
      @clearTreeViewRootMap() if reset
      updatePromises = []
      for root in @roots
        rootPath = utils.normalizePath root.directoryName.dataset.path
        if reset
          @treeViewRootsMap.set(rootPath, {root, customElements: {}})
        repoForRoot = null
        repoSubPath = null
        rootPathHasGitFolder = fs.existsSync(path.join(rootPath, '.git'))
        # Workaround: repoPayh is the real path of the repository. When rootPath
        # is a symbolic link, both do not not match and the repository is never
        # found. In this case, we expand the symbolic link, make it absolute and
        # normalize it to make sure it matches.
        rootPathNoSymlink = rootPath
        if (fs.isSymbolicLinkSync(rootPath))
          rootPathNoSymlink = utils.normalizePath(fs.realpathSync(rootPath))
        @repositoryMap.forEach (repo, repoPath) ->
          if not repoForRoot? and ((rootPathNoSymlink is repoPath) or
              (rootPathNoSymlink.indexOf(repoPath) is 0 and
              not rootPathHasGitFolder))
            repoSubPath = path.relative repoPath, rootPathNoSymlink
            repoForRoot = repo
        if repoForRoot?
          if not repoForRoot?
            repoForRoot = null
          updatePromises.push(
            @doUpdateRootNode root, repoForRoot, rootPath, repoSubPath
          )
      # Wait until all roots have been updated and then check
      # if we've a queued update roots job
      utils.settle(updatePromises)
      .catch((err) ->
        # Print errors in case there have been any... and then continute with
        # the following then block
        console.error err
      )
      .then(=>
        lastStatus = statusUpdatingRoots
        statusUpdatingRoots = ENUM_UPDATE_STATUS.NOT_UPDATING
        if lastStatus is ENUM_UPDATE_STATUS.QUEUED
          @updateRoots()
        else if lastStatus is ENUM_UPDATE_STATUS.QUEUED_RESET
          @updateRoots(true)
      )


    else if statusUpdatingRoots is ENUM_UPDATE_STATUS.UPDATING
      statusUpdatingRoots = ENUM_UPDATE_STATUS.QUEUED

    if statusUpdatingRoots is ENUM_UPDATE_STATUS.QUEUED and reset
      statusUpdatingRoots = ENUM_UPDATE_STATUS.QUEUED_RESET

  updateRootForRepo: (repo, repoPath) ->
    @updateRoots() # TODO Remove workaround...
    # TODO Solve concurrency issues when updating the roots
    # if @treeView? and @treeViewRootsMap?
    #   @treeViewRootsMap.forEach (root, rootPath) =>
    #     # Check if the root path is sub path of repo path
    #     repoSubPath = path.relative repoPath, rootPath
    #     if repoSubPath.indexOf('..') isnt 0 and root.root?
    #       @doUpdateRootNode root.root, repo, rootPath, repoSubPath

  doUpdateRootNode: (root, repo, rootPath, repoSubPath) ->
    customElements = @treeViewRootsMap.get(rootPath).customElements
    updatePromise = Promise.resolve()

    if @showProjectModifiedStatus and repo?
      updatePromise = updatePromise.then () ->
        if repoSubPath isnt ''
          return repo.getDirectoryStatus repoSubPath
        else
          # Workaround for the issue that 'getDirectoryStatus' doesn't work
          # on the repository root folder
          return utils.getRootDirectoryStatus repo

    return updatePromise.then((status) =>
      # Sanity check...
      return unless @roots?

      convStatus = @convertDirectoryStatus repo, status
      root.classList.remove('status-modified', 'status-added')
      root.classList.add("status-#{convStatus}") if convStatus?

      showHeaderGitStatus = @showBranchLabel or @showCommitsAheadLabel or
          @showCommitsBehindLabel

      if showHeaderGitStatus and repo? and not customElements.headerGitStatus?
        headerGitStatus = document.createElement('span')
        headerGitStatus.classList.add('tree-view-git-status')
        return @generateGitStatusText(headerGitStatus, repo).then ->
          customElements.headerGitStatus = headerGitStatus
          root.header.insertBefore(
            headerGitStatus, root.directoryName.nextSibling
          )
      else if showHeaderGitStatus and customElements.headerGitStatus?
        return @generateGitStatusText customElements.headerGitStatus, repo
      else if customElements.headerGitStatus?
        root.header.removeChild(customElements.headerGitStatus)
        customElements.headerGitStatus = null
    )

  generateGitStatusText: (container, repo) ->
    display = false
    head = null
    ahead = behind = 0

    gitFlowConfig = null

    # Ensure repo status is up-to-date
    repo.refreshStatus()
      .then ->
        return repo.getShortHead()
          .then((shorthead) ->
            head = shorthead
          )
      .then ->
        # Sanity check in case of thirdparty repos...
        if repo.getCachedUpstreamAheadBehindCount?
          return repo.getCachedUpstreamAheadBehindCount()
          .then((count) ->
            {ahead, behind} = count
          )
      .then =>
        if @gitFlowEnabled
          return repo.getFlowConfig()
          .then (data) ->
            gitFlowConfig = data
      .then =>
        # Reset styles
        container.className =  ''
        container.classList.add('tree-view-git-status')

        if @showBranchLabel and head?
          branchLabel = document.createElement('span')
          branchLabel.classList.add('branch-label')
          # Check if branch name can be a valid CSS class
          if /^[a-z_-][a-z\d_-]*$/i.test(head)
            container.classList.add('git-branch-' + head)
          branchLabel.textContent = head

          # Apply git flow changes if possible
          if @gitFlowEnabled and gitFlowConfig
            @applyGitFlowConfig branchLabel, gitFlowConfig

          # Mark as displayable
          display = true
        if @showCommitsAheadLabel and ahead > 0
          commitsAhead = document.createElement('span')
          commitsAhead.classList.add('commits-ahead-label')
          commitsAhead.textContent = ahead
          display = true
        if @showCommitsBehindLabel and behind > 0
          commitsBehind = document.createElement('span')
          commitsBehind.classList.add('commits-behind-label')
          commitsBehind.textContent = behind
          display = true

        if display
          container.classList.remove('hide')
        else
          container.classList.add('hide')

        container.innerHTML = ''
        container.appendChild branchLabel if branchLabel?
        container.appendChild commitsAhead if commitsAhead?
        container.appendChild commitsBehind if commitsBehind?

  ###
   Adds icons, prefixes and simplifies the branch name

   @param  {DOMNode} node
   @param  {Object} gitFlow
  ###
  applyGitFlowConfig: (node, gitFlow) ->
    return unless node and gitFlow

    branchPrefix = ''
    branchName = node.textContent
    workType = branchName

    ###
    Local function to determine the start of a branch. Since it's used
    repeatedly
    @param  {string} name   [description]
    @param  {string} prefix [description]
    @return [bool] Returns true if
    ###
    startsWith = (name, prefix) ->
      prefix == name.substr 0, prefix.length

    # Add Git Flow information
    if gitFlow.feature? and startsWith branchName, gitFlow.feature
      stateName = 'feature'
      branchPrefix = gitFlow.feature
      workType = 'a feature'
    else if gitFlow.hotfix? and startsWith branchName, gitFlow.hotfix
      stateName = 'hotfix'
      branchPrefix = gitFlow.hotfix
      workType = 'a hotfix'
    else if gitFlow.develop? and branchName == gitFlow.develop
      stateName = 'develop'
    else if gitFlow.master? and branchName == gitFlow.master
      stateName = 'master'
    else
      # We're nog on a Git Flow branch, don't do anything
      return

    # Add a data-flow attribute
    node.dataset.gitFlowState = stateName

    # Empty node
    node.innerText = ''

    # Add class names
    node.classList.add(
      'branch-label--flow',
      "branch-label--flow-#{stateName}"
    )

    # Remove the prefix from the branchname, or move the branchname to the
    # prefix in case of master / develop
    if branchPrefix
      branchName = branchName.substr(branchPrefix.length)
    else
      branchPrefix = branchName
      branchName = ''

    # If we want to use icons, make sure we remove the prefix
    if @gitFlowDisplayType > 1
      iconNode = document.createElement('span')
      iconNode.classList.add(
        "icon",
        "icon-#{flowIconMap[stateName]}"
        'branch-label__icon'
        "branch-label__icon--#{stateName}"
      )
      iconNode.title = "Working on #{workType}"
      node.appendChild iconNode

    # If we're asked to display the prefix or we're on master/develop, display
    # it.
    if branchName == '' or @gitFlowDisplayType < 3
      prefixNode = document.createElement('span')
      prefixNode.classList.add(
        'branch-label__prefix'
        "branch-label__prefix--#{stateName}"
      )
      prefixNode.textContent = branchPrefix
      node.appendChild prefixNode

    # Finally, if we have a branchname left over, add it as well.
    if branchName != ''
      node.appendChild document.createTextNode(branchName)

  convertDirectoryStatus: (repo, status) ->
    newStatus = null
    if repo.isStatusModified(status)
      newStatus = 'modified'
    else if repo.isStatusNew(status)
      newStatus = 'added'
    return newStatus
