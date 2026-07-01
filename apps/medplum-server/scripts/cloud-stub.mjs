// Auto-generated cloud SDK stub for Databricks deployments.

function createStub(name) {
  const error = () => {
    throw new Error(`Cloud SDK is disabled in this Databricks deployment (${name}).`);
  };
  const stub = new Proxy(error, {
    get(_target, prop) {
      if (prop === 'then') return undefined;
      if (prop === '__esModule') return true;
      if (prop === 'default') return createStub(`${name}.default`);
      return createStub(`${name}.${String(prop)}`);
    },
    construct() { return createStub(name); },
    apply() { return error(); },
  });
  return stub;
}

export class ResourceNotFoundException extends Error {
  constructor(message) {
    super(message);
    this.name = 'ResourceNotFoundException';
  }
}

export const BlobSASPermissions = createStub('BlobSASPermissions');
export const BlobServiceClient = createStub('BlobServiceClient');
export const ComprehendMedicalClient = createStub('ComprehendMedicalClient');
export const CopyObjectCommand = createStub('CopyObjectCommand');
export const CreateFunctionCommand = createStub('CreateFunctionCommand');
export const CreateNamespaceCommand = createStub('CreateNamespaceCommand');
export const CustomObjectsApi = createStub('CustomObjectsApi');
export const DefaultAzureCredential = createStub('DefaultAzureCredential');
export const DeleteFunctionCommand = createStub('DeleteFunctionCommand');
export const DetectEntitiesV2Command = createStub('DetectEntitiesV2Command');
export const GetDocumentTextDetectionCommand = createStub('GetDocumentTextDetectionCommand');
export const GetFunctionCommand = createStub('GetFunctionCommand');
export const GetFunctionConfigurationCommand = createStub('GetFunctionConfigurationCommand');
export const GetObjectCommand = createStub('GetObjectCommand');
export const GetParametersByPathCommand = createStub('GetParametersByPathCommand');
export const GetSecretValueCommand = createStub('GetSecretValueCommand');
export const GetTableCommand = createStub('GetTableCommand');
export const InvokeCommand = createStub('InvokeCommand');
export const InvokeWithResponseStreamCommand = createStub('InvokeWithResponseStreamCommand');
export const KubeConfig = createStub('KubeConfig');
export const LambdaClient = createStub('LambdaClient');
export const ListFunctionsCommand = createStub('ListFunctionsCommand');
export const ListLayerVersionsCommand = createStub('ListLayerVersionsCommand');
export const ListVersionsByFunctionCommand = createStub('ListVersionsByFunctionCommand');
export const PackageType = createStub('PackageType');
export const PatchStrategy = createStub('PatchStrategy');
export const PutObjectCommand = createStub('PutObjectCommand');
export const ResourceConflictException = createStub('ResourceConflictException');
export const S3Client = createStub('S3Client');
export const S3TablesClient = createStub('S3TablesClient');
export const SESv2Client = createStub('SESv2Client');
export const SSMClient = createStub('SSMClient');
export const SecretClient = createStub('SecretClient');
export const SecretManagerServiceClient = createStub('SecretManagerServiceClient');
export const SecretsManagerClient = createStub('SecretsManagerClient');
export const SendEmailCommand = createStub('SendEmailCommand');
export const StartDocumentTextDetectionCommand = createStub('StartDocumentTextDetectionCommand');
export const Storage = createStub('Storage');
export const TextractClient = createStub('TextractClient');
export const UpdateFunctionCodeCommand = createStub('UpdateFunctionCodeCommand');
export const UpdateFunctionConfigurationCommand = createStub('UpdateFunctionConfigurationCommand');
export const Upload = createStub('Upload');
export const getSignedUrl = createStub('getSignedUrl');
export const setHeaderOptions = createStub('setHeaderOptions');

export default createStub('cloud-sdk');
