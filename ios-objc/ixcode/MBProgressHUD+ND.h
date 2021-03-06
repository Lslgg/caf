
#import "MBProgressHUD.h"

@interface MBProgressHUD (ND)
+ (void)showSuccess:(NSString *)success toView:(UIView *)view;
+ (void)showError:(NSString *)error toView:(UIView *)view;

+ (MBProgressHUD *)showMessage:(NSString *)message toView:(UIView *)view;
+ (void)showTextOnly:(NSString *)text  view:(UIView *)view;

+ (void)showSuccess:(NSString *)success;
+ (void)showError:(NSString *)error;
+(void)showTextOnly:(NSString *)text;

+ (MBProgressHUD *)showMessage:(NSString *)message;

+ (void)hideHUDForView:(UIView *)view;
+ (void)hideHUD;

@end
