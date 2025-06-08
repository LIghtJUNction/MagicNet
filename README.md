# MagicNet
An Rmm project . Magic + Net
# MagicNet

![image](https://github.com/user-attachments/assets/f46c5c92-27df-4edd-851d-cae77ebd8540)

在安卓设备启用 tun 模式其实很简单 😊  
It's actually quite simple to enable tun mode on Android devices.

一个尽可能精简，希望每个人都能看懂的模块。  
A module that's as streamlined as possible, and easy for everyone to understand.
[查看模块](https://github.com/LIghtJUNction/RootManage-Module-Model/blob/MagicNet/MyModule/README.MD#%E5%AF%B9%E6%AF%94%E6%88%91%E7%9A%84bfm_config%E9%A1%B9%E7%9B%AE%E4%B8%BB%E8%A6%81%E6%94%B9%E5%8A%A8)
## Features ✨

- **安卓设备使用 tun 模式**  
  Use tun mode on Android devices.
- **无 DNS 泄露**  
  No DNS leaks.
- **多规则集内置，使用简单**  
  Multiple rule sets built-in, easy to use.

## Installation 📥

1. **Clone the repository**:  
   克隆仓库：
   ```sh
   git clone https://github.com/LIghtJUNction/RootManage-Module-Model.git
   ```
2. **Navigate to the project directory**:  
   进入项目目录：
   ```sh
   cd RootManage-Module-Model
   ```

## Usage 🛠️

- 修改示例模块以适应您的需求。  
  Modify the example modules to suit your needs.
- 按照提供的工作流程进行快速发布和部署。  
  Follow the provided workflows for quick release and deployment.

## Contribution Guidelines 🤝

- 所有用到的函数放在 `tools` 文件夹中。  
  All functions used are placed in the `tools` folder.
- 使用 `boot-complete.sh` 作为主要脚本，这个脚本的作用是在系统启动完毕后运行。  
  Use `boot-complete.sh` as the main script, which runs after the system starts up.
- 缺点是 Magisk 用不了了，此外 Magisk 还需要 `META-INF` 文件夹。  
  The downside is that Magisk won't work, and Magisk also requires the `META-INF` folder.
- 完全可以使用 `service.sh` 搭配一个是否开机完成的判断。  
  It is entirely possible to use `service.sh` with a boot completion check.
- 但是在这里，我认为精简和简单更重要。如需 Magisk 模块示例，请联系我。  
  However, here I believe simplicity and minimalism are more important. For a Magisk module example, please contact me.

> **Do one thing && Do it well.** Enjoy! 😎

## License 📄

This project is licensed under the GNU General Public License v3.0. See the [LICENSE](MyModule/LICENSE) file for details.  
此项目采用 GNU General Public License v3.0 许可证。详情请参见 [LICENSE](MyModule/LICENSE) 文件。

## Contact 📬

For further information or queries, you can reach out to [LIghtJUNction](https://github.com/LIghtJUNction).  
如需更多信息或有任何疑问，请联系 [LIghtJUNction](https://github.com/LIghtJUNction)。

## Changelog 📝

The changelog for this project is available in the [CHANGELOG.md](CHANGELOG.md) file.  
此项目的更新日志可在 [CHANGELOG.md](CHANGELOG.md) 文件中查看。

Feel free to modify the sections to better fit the specific details and requirements of your project.
