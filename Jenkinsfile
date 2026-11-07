// CI/CD for Smart Retail Inventory.
// This file lives in inventory-devops; the application code is checked out from inventory-app.
// Required Jenkins credentials:
//   dockerhub            Username/password (Docker Hub access token, Read & Write)
//   minikube-kubeconfig  Secret file (created by scripts/start-jenkins.sh)

pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '15'))
        timeout(time: 45, unit: 'MINUTES')
    }

    // GitHub cannot reach a laptop, so poll instead of using a webhook
    triggers {
        pollSCM('* * * * *')
    }

    parameters {
        booleanParam(name: 'SECURITY_SCAN', defaultValue: true,
                     description: 'Scan images with Trivy and stop on CRITICAL vulnerabilities')
    }

    environment {
        DOCKERHUB_USER = 'nivlev20'
        NAMESPACE      = 'inventory'
        INGRESS_HOST   = 'inventory.local'
    }

    stages {
        stage('Checkout') {
            steps {
                script {
                    env.APP_REPO = env.GIT_URL.replace('inventory-devops', 'inventory-app')
                }
                dir('app') {
                    git url: env.APP_REPO, branch: 'main'
                }
                script {
                    env.TAG = sh(script: 'git -C app rev-parse --short HEAD', returnStdout: true).trim()
                    env.BACKEND_IMAGE = "${env.DOCKERHUB_USER}/inventory-backend:${env.TAG}"
                    env.FRONTEND_IMAGE = "${env.DOCKERHUB_USER}/inventory-frontend:${env.TAG}"
                    currentBuild.description = "app ${env.TAG}"
                }
            }
        }

        stage('Lint') {
            parallel {
                stage('Backend') {
                    steps {
                        dir('app/backend') {
                            sh '''
                                python3 -m venv .venv
                                . .venv/bin/activate
                                pip install -q -r requirements-dev.txt
                                flake8 .
                            '''
                        }
                    }
                }
                stage('Frontend') {
                    steps {
                        dir('app/frontend') {
                            sh 'npm ci --no-audit --no-fund && npm run lint'
                        }
                    }
                }
            }
        }

        stage('Unit tests') {
            steps {
                dir('app/backend') {
                    sh '. .venv/bin/activate && pytest -q --junitxml=test-results.xml'
                }
            }
            post {
                always {
                    junit 'app/backend/test-results.xml'
                }
            }
        }

        stage('Build images') {
            steps {
                sh '''
                    docker build -t "$BACKEND_IMAGE" app/backend
                    docker build -t "$FRONTEND_IMAGE" app/frontend
                '''
            }
        }

        stage('Security scan') {
            when { expression { params.SECURITY_SCAN != false } }  // also true on the very first build, before parameters exist
            steps {
                // Fails the build before anything is pushed if a fixable CRITICAL issue is found
                sh '''
                    for image in "$BACKEND_IMAGE" "$FRONTEND_IMAGE"; do
                        docker run --rm \
                            -v /var/run/docker.sock:/var/run/docker.sock \
                            -v trivy-cache:/root/.cache/trivy \
                            aquasec/trivy:0.58.1 image \
                            --severity CRITICAL --ignore-unfixed --exit-code 1 --no-progress \
                            "$image"
                    done
                '''
            }
        }

        stage('Push images') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'dockerhub',
                                                  usernameVariable: 'DH_USER',
                                                  passwordVariable: 'DH_TOKEN')]) {
                    sh '''
                        echo "$DH_TOKEN" | docker login -u "$DH_USER" --password-stdin
                        docker push "$BACKEND_IMAGE"
                        docker push "$FRONTEND_IMAGE"
                    '''
                }
            }
            post {
                always {
                    sh 'docker logout || true'
                }
            }
        }

        stage('Deploy') {
            steps {
                withCredentials([file(credentialsId: 'minikube-kubeconfig', variable: 'KUBECONFIG')]) {
                    sh '''
                        kubectl apply -f k8s/00-namespace.yaml
                        ./scripts/create-secret.sh

                        # Manifests in Git keep the last released tag; deploy the tag built here
                        sed -i -E "s#(inventory-(backend|frontend)):[0-9a-f]{7}#\\1:${TAG}#" k8s/*.yaml
                        kubectl apply -f k8s/

                        kubectl rollout status deployment/backend  -n "$NAMESPACE" --timeout=180s
                        kubectl rollout status deployment/frontend -n "$NAMESPACE" --timeout=120s
                    '''
                    script { env.DEPLOYED = 'true' }
                }
            }
        }

        stage('Monitoring') {
            // Enabled once monitoring/values.yaml exists (stage 7 of the project)
            when { expression { fileExists('monitoring/values.yaml') } }
            steps {
                withCredentials([file(credentialsId: 'minikube-kubeconfig', variable: 'KUBECONFIG')]) {
                    sh '''
                        helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
                        helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
                            -n monitoring --create-namespace \
                            -f monitoring/values.yaml \
                            --wait --timeout 10m
                        if [ -d monitoring/manifests ]; then kubectl apply -f monitoring/manifests/; fi
                    '''
                }
            }
        }

        stage('API tests') {
            steps {
                withCredentials([file(credentialsId: 'minikube-kubeconfig', variable: 'KUBECONFIG')]) {
                    sh '''
                        NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
                        ./scripts/smoke-test.sh "http://$NODE_IP" "$INGRESS_HOST"
                    '''
                }
            }
        }
    }

    post {
        failure {
            script {
                if (env.DEPLOYED == 'true') {
                    echo 'Deployment failed its checks - rolling back to the previous version'
                    withCredentials([file(credentialsId: 'minikube-kubeconfig', variable: 'KUBECONFIG')]) {
                        sh '''
                            kubectl rollout undo deployment/backend  -n "$NAMESPACE" || true
                            kubectl rollout undo deployment/frontend -n "$NAMESPACE" || true
                        '''
                    }
                }
            }
        }
        success {
            echo "Deployed app version ${env.TAG}"
        }
    }
}
