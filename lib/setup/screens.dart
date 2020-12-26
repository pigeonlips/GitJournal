import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:dart_git/git.dart';
import 'package:dots_indicator/dots_indicator.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:function_types/function_types.dart';
import 'package:git_bindings/git_bindings.dart' as git_bindings;
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:time/time.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:gitjournal/analytics.dart';
import 'package:gitjournal/apis/githost_factory.dart';
import 'package:gitjournal/error_reporting.dart';
import 'package:gitjournal/repository.dart';
import 'package:gitjournal/settings.dart';
import 'package:gitjournal/setup/autoconfigure.dart';
import 'package:gitjournal/setup/button.dart';
import 'package:gitjournal/setup/clone_url.dart';
import 'package:gitjournal/setup/loading_error.dart';
import 'package:gitjournal/setup/repo_selector.dart';
import 'package:gitjournal/setup/sshkey.dart';
import 'package:gitjournal/ssh/keygen.dart';
import 'package:gitjournal/utils.dart';
import 'package:gitjournal/utils/logger.dart';

class GitHostSetupScreen extends StatefulWidget {
  final String repoFolderName;
  final String remoteName;
  final Func2<String, String, Future<void>> onCompletedFunction;

  GitHostSetupScreen({
    @required this.repoFolderName,
    @required this.remoteName,
    @required this.onCompletedFunction,
  });

  @override
  GitHostSetupScreenState createState() {
    return GitHostSetupScreenState();
  }
}

enum PageChoice0 { Unknown, KnownProvider, CustomProvider }
enum PageChoice1 { Unknown, Manual, Auto }
enum KeyGenerationChoice { Unknown, AutoGenerated, UserProvided }

class GitHostSetupScreenState extends State<GitHostSetupScreen> {
  var _pageCount = 1;

  var _pageChoice = [
    PageChoice0.Unknown,
    PageChoice1.Unknown,
  ];
  var _keyGenerationChoice = KeyGenerationChoice.Unknown;

  var _gitHostType = GitHostType.Unknown;
  GitHost _gitHost;
  GitHostRepo _gitHostRepo;
  String _autoConfigureMessage = "";
  String _autoConfigureErrorMessage = "";

  var _gitCloneUrl = "";
  var gitCloneErrorMessage = "";
  var publicKey = "";

  var pageController = PageController();
  int _currentPageIndex = 0;

  UserInfo _userInfo;

  Widget _buildPage(BuildContext context, int pos) {
    assert(_pageCount >= 1);

    if (pos == 0) {
      return GitHostChoicePage(
        onKnownGitHost: (GitHostType gitHostType) {
          setState(() {
            _gitHostType = gitHostType;
            gitCloneErrorMessage = "";
            _autoConfigureErrorMessage = "";
            _autoConfigureMessage = "";

            _pageChoice[0] = PageChoice0.KnownProvider;
            _pageCount = pos + 2;
            _nextPage();
          });
        },
        onCustomGitHost: () {
          setState(() {
            _pageChoice[0] = PageChoice0.CustomProvider;
            _pageCount = pos + 2;
            _nextPage();
          });
        },
      );
    }

    if (pos == 1) {
      assert(_pageChoice[0] != PageChoice0.Unknown);

      if (_pageChoice[0] == PageChoice0.CustomProvider) {
        return GitCloneUrlPage(
          doneFunction: (String sshUrl) {
            setState(() {
              _gitCloneUrl = sshUrl;

              _pageCount = pos + 2;
              _nextPage();
            });
          },
          initialValue: _gitCloneUrl,
        );
      }

      return GitHostAutoConfigureChoicePage(
        onDone: (GitHostSetupType setupType) {
          if (setupType == GitHostSetupType.Manual) {
            setState(() {
              _pageCount = pos + 2;
              _pageChoice[1] = PageChoice1.Manual;
              _nextPage();
            });
          } else if (setupType == GitHostSetupType.Auto) {
            setState(() {
              _pageCount = pos + 2;
              _pageChoice[1] = PageChoice1.Auto;
              _nextPage();
            });
          }
        },
      );
    }

    if (pos == 2) {
      if (_pageChoice[0] == PageChoice0.CustomProvider) {
        return GitHostSetupKeyChoice(
          onGenerateKeys: () {
            setState(() {
              _keyGenerationChoice = KeyGenerationChoice.AutoGenerated;
              _pageCount = pos + 2;

              _nextPage();
              _generateSshKey(context);
            });
          },
          onUserProvidedKeys: () {
            setState(() {
              _keyGenerationChoice = KeyGenerationChoice.UserProvided;
              _pageCount = pos + 2;
              _nextPage();
            });
          },
        );
      }

      assert(_pageChoice[1] != PageChoice1.Unknown);

      if (_pageChoice[1] == PageChoice1.Manual) {
        return GitCloneUrlKnownProviderPage(
          doneFunction: (String sshUrl) {
            setState(() {
              _pageCount = pos + 2;
              _gitCloneUrl = sshUrl;

              _nextPage();
            });
          },
          launchCreateUrlPage: _launchCreateRepoPage,
          gitHostType: _gitHostType,
          initialValue: _gitCloneUrl,
        );
      } else if (_pageChoice[1] == PageChoice1.Auto) {
        return GitHostSetupAutoConfigure(
          gitHostType: _gitHostType,
          onDone: (GitHost gitHost, UserInfo userInfo) {
            setState(() {
              _gitHost = gitHost;
              _userInfo = userInfo;
              _pageCount = pos + 2;

              _nextPage();
            });
          },
        );
      }
    }

    if (pos == 3) {
      if (_pageChoice[0] == PageChoice0.CustomProvider) {
        assert(_keyGenerationChoice != KeyGenerationChoice.Unknown);
        if (_keyGenerationChoice == KeyGenerationChoice.AutoGenerated) {
          return GitHostSetupSshKeyUnknownProvider(
            doneFunction: () {
              setState(() {
                _pageCount = pos + 2;
                _nextPage();
                _startGitClone(context);
              });
            },
            regenerateFunction: () {
              setState(() {
                publicKey = "";
              });
              _generateSshKey(context);
            },
            publicKey: publicKey,
            copyKeyFunction: _copyKeyToClipboard,
          );
        } else if (_keyGenerationChoice == KeyGenerationChoice.UserProvided) {
          return GitHostUserProvidedKeys(
            doneFunction:
                (String publicKey, String privateKey, String password) async {
              var settings = Provider.of<Settings>(context, listen: false);
              settings.sshPublicKey = publicKey;
              settings.sshPrivateKey = privateKey;
              settings.sshPassword = password;
              settings.save();

              setState(() {
                this.publicKey = publicKey;
                _pageCount = pos + 2;
                _nextPage();
                _startGitClone(context);
              });
            },
          );
        }
      }

      if (_pageChoice[1] == PageChoice1.Manual) {
        return GitHostSetupKeyChoice(
          onGenerateKeys: () {
            setState(() {
              _keyGenerationChoice = KeyGenerationChoice.AutoGenerated;
              _pageCount = pos + 2;

              _nextPage();
              _generateSshKey(context);
            });
          },
          onUserProvidedKeys: () {
            setState(() {
              _keyGenerationChoice = KeyGenerationChoice.UserProvided;
              _pageCount = pos + 2;
              _nextPage();
            });
          },
        );
      } else if (_pageChoice[1] == PageChoice1.Auto) {
        return GitHostSetupRepoSelector(
          gitHost: _gitHost,
          userInfo: _userInfo,
          onDone: (GitHostRepo repo) {
            setState(() {
              _gitHostRepo = repo;
              _pageCount = pos + 2;
              _nextPage();
              _completeAutoConfigure();
            });
          },
        );
      }

      assert(false);
    }

    if (pos == 4) {
      if (_pageChoice[0] == PageChoice0.CustomProvider) {
        return GitHostSetupLoadingErrorPage(
          loadingMessage: tr('setup.cloning'),
          errorMessage: gitCloneErrorMessage,
        );
      }

      if (_pageChoice[1] == PageChoice1.Manual) {
        assert(_keyGenerationChoice != KeyGenerationChoice.Unknown);
        if (_keyGenerationChoice == KeyGenerationChoice.AutoGenerated) {
          return GitHostSetupSshKeyKnownProvider(
            doneFunction: () {
              setState(() {
                _pageCount = 6;

                _nextPage();
                _startGitClone(context);
              });
            },
            regenerateFunction: () {
              setState(() {
                publicKey = "";
              });
              _generateSshKey(context);
            },
            publicKey: publicKey,
            copyKeyFunction: _copyKeyToClipboard,
            openDeployKeyPage: _launchDeployKeyPage,
          );
        } else if (_keyGenerationChoice == KeyGenerationChoice.UserProvided) {
          return GitHostUserProvidedKeys(
            doneFunction: (publicKey, privateKey, password) async {
              var settings = Provider.of<Settings>(context, listen: false);
              settings.sshPublicKey = publicKey;
              settings.sshPrivateKey = privateKey;
              settings.sshPassword = password;
              settings.save();

              setState(() {
                this.publicKey = publicKey;
                _pageCount = pos + 2;
                _nextPage();
                _startGitClone(context);
              });
            },
          );
        }
      } else if (_pageChoice[1] == PageChoice1.Auto) {
        return GitHostSetupLoadingErrorPage(
          loadingMessage: _autoConfigureMessage,
          errorMessage: _autoConfigureErrorMessage,
        );
      }
    }

    if (pos == 5) {
      return GitHostSetupLoadingErrorPage(
        loadingMessage: tr('setup.cloning'),
        errorMessage: gitCloneErrorMessage,
      );
    }

    assert(_pageChoice[0] != PageChoice0.CustomProvider);

    assert(false, "Pos is $pos");
    return null;
  }

  @override
  Widget build(BuildContext context) {
    var pageView = PageView.builder(
      controller: pageController,
      itemBuilder: _buildPage,
      itemCount: _pageCount,
      onPageChanged: (int pageNum) {
        setState(() {
          _currentPageIndex = pageNum;
          _pageCount = _currentPageIndex + 1;
        });
      },
    );

    var body = Container(
      width: double.infinity,
      height: double.infinity,
      child: Stack(
        alignment: FractionalOffset.bottomCenter,
        children: <Widget>[
          pageView,
          DotsIndicator(
            dotsCount: _pageCount,
            position: _currentPageIndex,
            decorator: DotsDecorator(
              activeColor: Theme.of(context).primaryColorDark,
            ),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16.0),
    );

    var scaffold = Scaffold(
      body: Stack(
        children: <Widget>[
          body,
          if (Platform.isIOS)
            SafeArea(
              child: InkWell(
                child: Container(
                  child: const Icon(Icons.arrow_back, size: 32.0),
                  padding: const EdgeInsets.all(8.0),
                ),
                onTap: () {
                  _removeRemote();
                  Navigator.of(context).pop();
                },
              ),
            ),
        ],
      ),
    );

    return WillPopScope(
      onWillPop: () async {
        if (_currentPageIndex != 0) {
          pageController.previousPage(
            duration: 200.milliseconds,
            curve: Curves.easeIn,
          );
          return false;
        }

        _removeRemote();
        return true;
      },
      child: scaffold,
    );
  }

  Future<void> _removeRemote() async {
    var repo = Provider.of<Repository>(context, listen: false);
    var basePath = repo.gitBaseDirectory;

    var repoPath = p.join(basePath, widget.repoFolderName);

    try {
      var repo = await GitRepository.load(repoPath);
      await repo.removeRemote(widget.remoteName);
    } on Exception catch (e, stacktrace) {
      Log.e("Failed to remove remote", ex: e, stacktrace: stacktrace);
      logExceptionWarning(e, stacktrace);
    }
  }

  void _nextPage() {
    pageController.nextPage(
      duration: 200.milliseconds,
      curve: Curves.easeIn,
    );
  }

  void _generateSshKey(BuildContext context) {
    if (publicKey.isNotEmpty) {
      return;
    }

    var comment = "GitJournal-" +
        Platform.operatingSystem +
        "-" +
        DateTime.now().toIso8601String().substring(0, 10); // only the date

    generateSSHKeys(comment: comment).then((SshKey sshKey) {
      var settings = Provider.of<Settings>(context, listen: false);
      settings.sshPublicKey = sshKey.publicKey;
      settings.sshPrivateKey = sshKey.privateKey;
      settings.sshPassword = sshKey.password;
      settings.save();

      setState(() {
        publicKey = sshKey.publicKey;
        Log.d("PublicKey: " + publicKey);
        _copyKeyToClipboard(context);
      });
    });
  }

  void _copyKeyToClipboard(BuildContext context) {
    Clipboard.setData(ClipboardData(text: publicKey));
    showSnackbar(context, tr('setup.sshKey.copied'));
  }

  void _launchDeployKeyPage() async {
    var canLaunch = _gitCloneUrl.startsWith("git@github.com:") ||
        _gitCloneUrl.startsWith("git@gitlab.com:");
    if (!canLaunch) {
      return;
    }

    var lastIndex = _gitCloneUrl.lastIndexOf(".git");
    if (lastIndex == -1) {
      lastIndex = _gitCloneUrl.length;
    }

    var repoName =
        _gitCloneUrl.substring(_gitCloneUrl.lastIndexOf(":") + 1, lastIndex);

    final gitHubUrl = 'https://github.com/' + repoName + '/settings/keys/new';
    final gitLabUrl = 'https://gitlab.com/' +
        repoName +
        '/-/settings/repository/#js-deploy-keys-settings';

    try {
      if (_gitCloneUrl.startsWith("git@github.com:")) {
        Log.i("Launching $gitHubUrl");
        await launch(gitHubUrl);
      } else if (_gitCloneUrl.startsWith("git@gitlab.com:")) {
        Log.i("Launching $gitLabUrl");
        await launch(gitLabUrl);
      }
    } catch (err, stack) {
      Log.d('_launchDeployKeyPage: ' + err.toString());
      Log.d(stack.toString());
    }
  }

  void _launchCreateRepoPage() async {
    assert(_gitHostType != GitHostType.Unknown);

    try {
      if (_gitHostType == GitHostType.GitHub) {
        await launch("https://github.com/new");
      } else if (_gitHostType == GitHostType.GitLab) {
        await launch("https://gitlab.com/projects/new");
      }
    } catch (err, stack) {
      // FIXME: Error handling?
      Log.d("_launchCreateRepoPage: " + err.toString());
      Log.d(stack.toString());
    }
  }

  void _startGitClone(BuildContext context) async {
    setState(() {
      gitCloneErrorMessage = "";
    });

    var repo = Provider.of<Repository>(context, listen: false);
    var basePath = repo.gitBaseDirectory;

    var settings = Provider.of<Settings>(context, listen: false);
    var repoPath = p.join(basePath, widget.repoFolderName);
    Log.i("RepoPath: $repoPath");

    String error;
    try {
      var repo = await GitRepository.load(repoPath);
      await repo.addOrUpdateRemote(widget.remoteName, _gitCloneUrl);

      var repoN = git_bindings.GitRepo(folderPath: repoPath);
      await repoN.fetch(
        remote: widget.remoteName,
        publicKey: settings.sshPublicKey,
        privateKey: settings.sshPrivateKey,
        password: settings.sshPassword,
      );
    } on Exception catch (e, stacktrace) {
      Log.e("Failed to add remote", ex: e, stacktrace: stacktrace);
      error = e.toString();
    }

    if (error != null && error.isNotEmpty) {
      Log.i("Not completing gitClone because of error");
      setState(() {
        logEvent(Event.GitHostSetupGitCloneError, parameters: {
          'error': error,
        });
        gitCloneErrorMessage = error;
      });
      return;
    }

    logEvent(
      Event.GitHostSetupComplete,
      parameters: _buildOnboardingAnalytics(),
    );
    await widget.onCompletedFunction(widget.repoFolderName, widget.remoteName);
    Navigator.pop(context);
  }

  Future<void> _completeAutoConfigure() async {
    Log.d("Starting autoconfigure copletion");

    try {
      Log.i("Generating SSH Key");
      setState(() {
        _autoConfigureMessage = tr('setup.sshKey.generate');
      });
      var sshKey = await generateSSHKeys(comment: "GitJournal");
      var settings = Provider.of<Settings>(context, listen: false);
      settings.sshPublicKey = sshKey.publicKey;
      settings.sshPrivateKey = sshKey.privateKey;
      settings.sshPassword = sshKey.password;
      settings.save();

      setState(() {
        publicKey = sshKey.publicKey;
      });

      Log.i("Adding as a deploy key");
      _autoConfigureMessage = tr('setup.sshKey.addDeploy');

      await _gitHost.addDeployKey(publicKey, _gitHostRepo.fullName);
    } on Exception catch (e, stacktrace) {
      _handleGitHostException(e, stacktrace);
      return;
    }

    setState(() {
      _gitCloneUrl = _gitHostRepo.cloneUrl;
      _pageCount += 1;

      _nextPage();
      _startGitClone(context);
    });
  }

  void _handleGitHostException(Exception e, StackTrace stacktrace) {
    Log.d("GitHostSetupAutoConfigureComplete: " + e.toString());
    setState(() {
      _autoConfigureErrorMessage = e.toString();
      logEvent(
        Event.GitHostSetupError,
        parameters: {
          'errorMessage': _autoConfigureErrorMessage,
        },
      );

      logException(e, stacktrace);
    });
  }

  Map<String, String> _buildOnboardingAnalytics() {
    var map = <String, String>{};

    if (_gitCloneUrl.contains("github.com")) {
      map["host_type"] = "GitHub";
    } else if (_gitCloneUrl.contains("gitlab.org")) {
      map["host_type"] = "GitLab.org";
    } else if (_gitCloneUrl.contains("gitlab")) {
      map["host_type"] = "GitLab";
    }

    var ch0 = _pageChoice[0] as PageChoice0;
    map["provider_choice"] = ch0.toString().replaceFirst("PageChoice0.", "");

    var ch1 = _pageChoice[1] as PageChoice1;
    map["setup_manner"] = ch1.toString().replaceFirst("PageChoice1.", "");

    map["key_generation"] = _keyGenerationChoice
        .toString()
        .replaceFirst("KeyGenerationChoice.", "");

    return map;
  }
}

class GitHostChoicePage extends StatelessWidget {
  final Func1<GitHostType, void> onKnownGitHost;
  final Func0<void> onCustomGitHost;

  GitHostChoicePage({
    @required this.onKnownGitHost,
    @required this.onCustomGitHost,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      child: Column(
        children: <Widget>[
          Text(
            tr('setup.host.title'),
            style: Theme.of(context).textTheme.headline5,
          ),
          const SizedBox(height: 16.0),
          GitHostSetupButton(
            text: "GitHub",
            iconUrl: 'assets/icon/github-icon.png',
            onPressed: () {
              onKnownGitHost(GitHostType.GitHub);
            },
          ),
          const SizedBox(height: 8.0),
          GitHostSetupButton(
            text: "GitLab",
            iconUrl: 'assets/icon/gitlab-icon.png',
            onPressed: () async {
              onKnownGitHost(GitHostType.GitLab);
            },
          ),
          const SizedBox(height: 8.0),
          GitHostSetupButton(
            text: tr('setup.host.custom'),
            onPressed: () async {
              onCustomGitHost();
            },
          ),
        ],
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
      ),
    );
  }
}

enum GitHostSetupType {
  Auto,
  Manual,
}

class GitHostAutoConfigureChoicePage extends StatelessWidget {
  final Func1<GitHostSetupType, void> onDone;

  GitHostAutoConfigureChoicePage({@required this.onDone});

  @override
  Widget build(BuildContext context) {
    return Container(
      child: Column(
        children: <Widget>[
          Text(
            tr('setup.autoConfigure.title'),
            style: Theme.of(context).textTheme.headline5,
          ),
          const SizedBox(height: 16.0),
          GitHostSetupButton(
            text: tr('setup.autoConfigure.automatic'),
            onPressed: () {
              onDone(GitHostSetupType.Auto);
            },
          ),
          const SizedBox(height: 8.0),
          GitHostSetupButton(
            text: tr('setup.autoConfigure.manual'),
            onPressed: () async {
              onDone(GitHostSetupType.Manual);
            },
          ),
        ],
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
      ),
    );
  }
}
