//
//  Plugin.swift
//  HybridDemo
//
//  Created by wc on 13/08/2017.
//  Copyright © 2017 DianQK. All rights reserved.
//

import UIKit
import RxSwift
import RxCocoa
import WebKit
import SnapKit
import SwiftyJSON

struct TitlePlugin: HybridPlugin {
    
    static var name: String {
        return "title"
    }
    
    static func didReceive(message: Observable<(message: JSON, webView: WKWebView, viewController: UIViewController)>) -> Disposable {
        return message
            .subscribe(onNext: { (message, webView, viewController) in
                let title = message["title"].string
                viewController.title = title
            })
    }
    
}

public protocol CallBackHybridPlugin: HybridPlugin {
    
    static func didReceive(message: JSON, webView: WKWebView, viewController: UIViewController) -> Observable<JSON>
    
}


extension CallBackHybridPlugin {
    
    public static func didReceive(message: Observable<(message: JSON, webView: WKWebView, viewController: UIViewController)>) -> Disposable {
        return message
            .flatMap { (message, webView, viewController) -> Observable<(callbackId: String, response: JSON, webView: WKWebView)> in
                let callbackId = message["callbackId"].stringValue
                let content = message["content"]
                return didReceive(message: content, webView: webView, viewController: viewController)
                    .map { (response) in
                        return (callbackId: callbackId, response: response, webView: webView)
                }
            }
            .subscribe(onNext: { (callbackId, response, webView) in
                webView.evaluateJavaScript("window.$native.callbacks['\(callbackId)'].callback(\(response.rawString() ?? "{}"));", completionHandler: nil)
            })
    }
    
}


struct SelectImagePlugin: CallBackHybridPlugin {
    
    static var name: String {
        return "selectImage"
    }
    
    static func didReceive(message: JSON, webView: WKWebView, viewController: UIViewController) -> Observable<JSON> {
        return Observable<UIImagePickerControllerSourceType>
            .create { (observer) -> Disposable in
                let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
                alert.addAction(UIAlertAction(title: "拍照", style: .default, handler: { _ in
                    observer.onNext(UIImagePickerControllerSourceType.camera)
                    observer.onCompleted()
                }))
                alert.addAction(UIAlertAction(title: "从相册选择", style: .default, handler: { _ in
                    observer.onNext(UIImagePickerControllerSourceType.photoLibrary)
                    observer.onCompleted()
                }))
                alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
                viewController.present(alert, animated: true, completion: nil)
                return Disposables.create {
                    alert.dismiss(animated: true, completion: nil)
                }
            }
            .flatMap { sourceType in
                UIImagePickerController.rx.createWithParent(viewController) { picker in
                    picker.sourceType = sourceType
                    picker.allowsEditing = true
                }
            }
            .flatMap { $0.rx.didFinishPickingMediaWithInfo }
            .take(1)
            .map { return $0[UIImagePickerControllerEditedImage] as! UIImage }
            .map { UIImagePNGRepresentation($0)!.base64EncodedString() }
            .map { return JSON(["image": "data:img/jpg;base64," + $0]) }
    }
    
}

struct RightBarTitlePlugin: HybridPlugin {
    
    static var name: String {
        return "rightBarTitle"
    }
    
    static func didReceive(message: Observable<(message: JSON, webView: WKWebView, viewController: UIViewController)>) -> Disposable {
        return message
            .flatMapLatest { (message, webView, viewController) -> Observable<WKWebView> in
                let title = message["title"].stringValue
                if title.isEmpty {
                    viewController.navigationItem.rightBarButtonItem = nil
                    return Observable.empty()
                }
                let rightBarButtonItem = UIBarButtonItem(title: title, style: UIBarButtonItemStyle.plain, target: nil, action: nil)
                viewController.navigationItem.rightBarButtonItem = rightBarButtonItem
                return rightBarButtonItem.rx.tap
                    .map { webView }
            }
            .subscribe(onNext: { (webView) in
                webView.evaluateJavaScript("window.$native.rightBarClick();", completionHandler: nil)
            })
    }

}

struct LogPlugin: HybridPlugin {
    
    static var name: String {
        return "log"
    }
    
    static func didReceive(message: Observable<(message: JSON, webView: WKWebView, viewController: UIViewController)>) -> Disposable {
        return message
            .subscribe(onNext: { (message, webView, viewController) in
                print(message)
            })
    }
    
}

struct DisplayImagePlugin: CallBackHybridPlugin {
    
    static var name: String {
        return "displayImage"
    }

    static func didReceive(message: JSON, webView: WKWebView, viewController: UIViewController) -> Observable<JSON> {
        guard let image = URL(string: message["image"].stringValue).flatMap({ try? Data(contentsOf: $0) }).flatMap({ UIImage(data: $0) }) else {
            return Observable.just(JSON([:]))
        }
        let frame = CGRect(
            x: message["x"].doubleValue,
            y: message["y"].doubleValue + Double(webView.frame.origin.y) - Double(webView.scrollView.contentOffset.y),
            width: message["width"].doubleValue,
            height: message["height"].doubleValue
        )
        let keyWindow = UIApplication.shared.keyWindow!
        let displayView = DisplayView(frame: keyWindow.bounds)
        displayView.display(image: image, frame: frame)
        return displayView.displayFinished.ifEmpty(default: ()).map { JSON([:]) }
    }
    
    private class DisplayView: UIView {
        
        let imageView = UIImageView()
        let disposeBag = DisposeBag()
        let visualEffectView = UIVisualEffectView(effect: UIBlurEffect(style: UIBlurEffectStyle.light))
        
        var originFrame = CGRect.zero
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            
            self.addSubview(visualEffectView)
            visualEffectView.frame = self.bounds
            self.visualEffectView.alpha = 0
            
            self.addSubview(imageView)
            self.isUserInteractionEnabled = true
            let tap = UITapGestureRecognizer()
            tap.rx.event
                .subscribe(onNext: { [weak self] _ in
                    UIView.animate(withDuration: 0.3, animations: {
                        if let `self` = self {
                            self.visualEffectView.alpha = 0
                            self.imageView.frame = self.originFrame
                        }
                    }, completion: { _ in
                        self?.displayFinished.onNext(())
                    })
                })
                .disposed(by: disposeBag)
            self.addGestureRecognizer(tap)
            self.displayFinished.debounce(0.1, scheduler: MainScheduler.asyncInstance)
                .subscribe(onNext: { [weak self] in
                    self?.removeFromSuperview()
                })
                .disposed(by: disposeBag)
        }
        
        required init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        func display(image: UIImage, frame: CGRect) {
            self.originFrame = frame
            self.imageView.image = image
            self.imageView.frame = frame
            let view = UIApplication.shared.keyWindow!
            view.addSubview(self)
            UIView.animate(withDuration: 0.3, animations: {
                self.visualEffectView.alpha = 1
                let height = view.bounds.width / frame.width * frame.height
                let y = (view.bounds.height - height) / 2
                self.imageView.frame = CGRect(x: 0, y: y, width: view.bounds.width, height: height)
            })
        }
        
        let displayFinished = PublishSubject<()>()
    }
    
}
