# Helm ��ʲô����
Helm �� Kubernetes �İ����������������������������� Ubuntu ��ʹ�õ�apt��Centos��ʹ�õ�yum ����Python�е� pip һ�����ܿ��ٲ��ҡ����غͰ�װ�������Helm �ɿͻ������ helm �ͷ������� Tiller ���, �ܹ���һ��K8S��Դ���ͳһ����, �ǲ��ҡ������ʹ��ΪKubernetes�������������ѷ�ʽ��
# Helm �����ʲôʹ�㣿
�� Kubernetes�в���һ������ʹ�õ�Ӧ�ã���Ҫ�漰���ܶ�� Kubernetes ��Դ�Ĺ�ͬЭ���������㰲װһ�� WordPress ���ͣ��õ���һЩ Kubernetes (����ȫ�����k8s)��һЩ��Դ���󣬰��� Deployment ���ڲ���Ӧ�á�Service �ṩ�����֡�Secret ���� WordPress ���û��������룬���ܻ���Ҫ pv �� pvc ���ṩ�־û����񡣲��� WordPress �����Ǵ洢��mariadb����ģ�������Ҫ mariadb ����������������� WordPress����Щ k8s ��Դ���ڷ�ɢ����������й���ֱ��ͨ�� kubectl ������һ��Ӧ�ã���ᷢ����ʮ�ֵ��ۡ�
�����ܽ����ϣ������� k8s �в���һ��Ӧ�ã�ͨ���������¼������⣺
* ���ͳһ�������ú͸�����Щ��ɢ�� k8s ��Ӧ����Դ�ļ�
* ��ηַ��͸���һ��Ӧ��ģ��
* ��ν�Ӧ�õ�һϵ����Դ����һ�����������
see : https://www.hi-linux.com/posts/21466.html
# ����
   minikube v1.15��helm3��ubuntu 16��harbor 1.8.2
* ��ȡhelm3 see https://github.com/helm/helm/releases
* ��װ see https://helm.sh/docs/intro/install/
  1. ��ѹtar�� tar -zxvf helm-v3.0.0-linux-amd64.tgz
  2. mv linux-amd64/helm /usr/local/bin/helm
  3. helm version ���汾
# ��������
 see https://v3.helm.sh/docs/intro/using_helm/
# ʹ��harbor����chart����
* uiģʽ����https://github.com/goharbor/harbor/blob/master/docs/user_guide.md#manage-helm-charts
* cliģʽ ���Ȱ�װplugin�� `helm plugin install https://github.com/chartmuseum/helm-push`
  helm3�����ܰ��ձ���repo list�����ƽ���push �������Ҫֱ��ʹ��url�� ���harbor��https��ʽ������Ҫ��Ӱ䷢��ca.crt
 ���� `helm push --ca-file=ca.crt --username=admin --password=passw0rd chart_repo/hello-helm-0.1.0.tgz https://192.168.1.123:443/chartrepo/chartrepo`