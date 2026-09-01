// common/utils/BusinessError.ets
export class BusinessError extends Error {
  code: number;

  constructor(code: number, message: string) {
    super(message); // 调用父类 Error 的构造函数
    this.name = 'BusinessError';
    this.code = code;
  }
}
