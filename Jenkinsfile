pipeline {
  agent {
    label 'macos'
  }

  // Jenkins macos agents need macOS 26.5+, Xcode 27 with an iOS 26.5+
  // simulator runtime, and rbenv/ruby-build. The pinned Ruby is installed as needed.
  // Checks use workspace-local output and no signing or release credentials.
  options {
    buildDiscarder(logRotator(numToKeepStr: '30'))
    skipDefaultCheckout()
    timeout(time: 60, unit: 'MINUTES')
  }

  stages {
    stage('Checkout') {
      steps {
        script {
          def scmVars = checkout scm
          def checkoutCommit = scmVars.GIT_COMMIT?.trim()
          if (!checkoutCommit) {
            error('checkout scm did not provide the checked-out commit SHA')
          }
          env.CHECKED_OUT_COMMIT = checkoutCommit
        }
      }
    }

    stage('Style Check') {
      steps {
        sh 'bash ci/check.sh style'
      }
    }

    stage('Prepare Ruby') {
      steps {
        lock(resource: "ruby-install-${env.NODE_NAME}") {
          sh 'rbenv install -s'
        }
        sh 'ruby --version'
      }
    }

    stage('Compile') {
      steps {
        sh 'bash ci/check.sh compile'
      }
    }

    stage('Test') {
      steps {
        sh 'bash ci/check.sh test'
      }
      post {
        // Keep Xcode's result bundles when tests fail as well as when they pass.
        // Convert Xcode result bundles to JUnit XML so Jenkins records individual
        // test cases, including failures from a partially completed test run.
        always {
          sh '''
            for result in .ci/TestResults/*.xcresult; do
              [ -d "$result" ] || continue
              ci/xcresult-to-junit.rb "$result" "${result%.xcresult}.xml"
            done
          '''
          junit allowEmptyResults: true, testResults: '.ci/TestResults/*.xml'
          archiveArtifacts artifacts: '.ci/TestResults/**/*.xcresult/**', allowEmptyArchive: true, onlyIfSuccessful: false
        }
      }
    }

    stage('Trigger Artifact Build') {
      when {
        allOf {
          branch 'main'
          not { changeRequest() }
          expression {
            def allowedCauses = [
              'hudson.triggers.SCMTrigger$SCMTriggerCause',
              'jenkins.branch.BranchEventCause',
            ]
            def excludedCauseSuffixes = [
              'UserIdCause',
              'ReplayCause',
              'TimerTriggerCause',
              'RebuildCause',
              'RestartDeclarativePipelineCause',
            ]
            def causeClasses = currentBuild.getBuildCauses().collect { cause -> cause._class }
            causeClasses.any { cause -> cause in allowedCauses } &&
              !causeClasses.any { cause -> excludedCauseSuffixes.any { suffix -> cause.endsWith(suffix) } }
          }
        }
      }
      steps {
        build job: 'chahua/chahua-apple-build',
          wait: false,
          parameters: [
            string(name: 'GIT_COMMIT_SHA', value: env.CHECKED_OUT_COMMIT),
          ]
      }
    }
  }
}
