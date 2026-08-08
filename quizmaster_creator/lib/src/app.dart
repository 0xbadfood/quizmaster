import 'package:flutter/material.dart';

import 'screens/create_screen.dart';
import 'screens/run_setup_screen.dart';
import 'screens/runs_screen.dart';
import 'state/app_controller.dart';
import 'theme/app_theme.dart';

class QuizmasterCreatorApp extends StatelessWidget {
  const QuizmasterCreatorApp({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Quizmaster Creator',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: CreatorShell(controller: controller),
    );
  }
}

class CreatorShell extends StatefulWidget {
  const CreatorShell({super.key, required this.controller});

  final AppController controller;

  @override
  State<CreatorShell> createState() => _CreatorShellState();
}

class _CreatorShellState extends State<CreatorShell> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  void _onControllerChanged() {
    final notice = widget.controller.takeNotice();
    if (notice == null || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(notice)));
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        if (controller.initializing) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return Scaffold(
          appBar: AppBar(
            toolbarHeight: 60,
            titleSpacing: 16,
            title: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: AppColors.green,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.quiz_outlined,
                    color: Colors.white,
                    size: 21,
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Quizmaster Creator',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Tooltip(
                  message: controller.connected
                      ? 'API connected'
                      : 'API unavailable',
                  child: Icon(
                    controller.connected
                        ? Icons.cloud_done_outlined
                        : Icons.cloud_off_outlined,
                    color: controller.connected
                        ? AppColors.green
                        : AppColors.coral,
                    size: 22,
                  ),
                ),
              ),
            ],
            backgroundColor: AppColors.surface,
            surfaceTintColor: Colors.transparent,
            bottom: const PreferredSize(
              preferredSize: Size.fromHeight(1),
              child: Divider(height: 1),
            ),
          ),
          body: IndexedStack(
            index: controller.selectedScreen,
            children: [
              RunSetupScreen(controller: controller),
              CreateScreen(controller: controller),
              RunsScreen(controller: controller),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: controller.selectedScreen,
            onDestinationSelected: controller.selectScreen,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.tune_outlined),
                selectedIcon: Icon(Icons.tune),
                label: 'Setup',
              ),
              NavigationDestination(
                icon: Icon(Icons.add_box_outlined),
                selectedIcon: Icon(Icons.add_box),
                label: 'Create',
              ),
              NavigationDestination(
                icon: Icon(Icons.fact_check_outlined),
                selectedIcon: Icon(Icons.fact_check),
                label: 'Runs',
              ),
            ],
          ),
        );
      },
    );
  }
}
