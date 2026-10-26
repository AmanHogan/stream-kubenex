// Build the downloader image in-cluster with kaniko, push it to the LAN registry,
// then bump the tag in k3s-data-platform. ArgoCD sees that commit and deploys it.
// No Docker on the Mac, no port-forward, no crane.

pipeline {
  agent {
    kubernetes {
      yaml '''
apiVersion: v1
kind: Pod
spec:
  containers:
    - name: kaniko
      image: gcr.io/kaniko-project/executor:v1.23.2-debug
      command: ["sleep"]
      args: ["infinity"]
      tty: true
    - name: git
      image: alpine/git:2.45.2
      command: ["sleep"]
      args: ["infinity"]
      tty: true
'''
    }
  }

  // No webhook: GitHub cannot reach Jenkins on the LAN. Poll instead.
  triggers {
    pollSCM('H/3 * * * *')
  }

  options {
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '20'))
  }

  environment {
    REGISTRY   = "192.168.4.245:5001"
    IMAGE      = "stream-kubenex"
    INFRA_REPO = "github.com/AmanHogan/k3s-data-platform.git"
    MANIFEST   = "manifests/stream-kubenex/deployment.yaml"
  }

  stages {
    stage('Tag') {
      steps {
        script {
          // Build number for order, commit for traceability: e.g. 7-3482c63.
          env.TAG = "${env.BUILD_NUMBER}-${env.GIT_COMMIT.take(7)}"
        }
        echo "Image tag: ${env.TAG}"
      }
    }

    stage('Build & Push image') {
      steps {
        container('kaniko') {
          // The cache repo keeps the apt/pip/deno layers, so a code-only change
          // builds in about a minute.
          sh '''
            /kaniko/executor \
              --context "$(pwd)/downloader" \
              --dockerfile "$(pwd)/downloader/Dockerfile" \
              --destination ${REGISTRY}/${IMAGE}:${TAG} \
              --destination ${REGISTRY}/${IMAGE}:latest \
              --cache=true --cache-repo=${REGISTRY}/${IMAGE}/cache \
              --insecure --skip-tls-verify --insecure-registry=${REGISTRY}
          '''
        }
      }
    }

    stage('Update manifest & push (GitOps)') {
      steps {
        container('git') {
          withCredentials([usernamePassword(credentialsId: 'github-pat',
                                             usernameVariable: 'GIT_USER',
                                             passwordVariable: 'GIT_TOKEN')]) {
            sh '''
              git config --global user.email "jenkins@k3s.local"
              git config --global user.name "jenkins-ci"

              rm -rf infra
              git clone "https://${GIT_USER}:${GIT_TOKEN}@${INFRA_REPO}" infra
              cd infra

              # Only the app container: its image is the one under ${REGISTRY}/${IMAGE}.
              sed -i "s#image: .*/${IMAGE}:.*#image: ${REGISTRY}/${IMAGE}:${TAG}#" ${MANIFEST}

              git add ${MANIFEST}
              git commit -m "Deploy ${IMAGE}:${TAG}" || { echo "No manifest change"; exit 0; }
              git push origin master
            '''
          }
        }
      }
    }
  }

  post {
    success {
      echo "Built ${REGISTRY}/${IMAGE}:${TAG} and updated the manifest. ArgoCD will deploy it."
    }
  }
}
